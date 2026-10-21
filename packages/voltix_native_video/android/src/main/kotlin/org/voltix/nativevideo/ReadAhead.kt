package org.voltix.nativevideo

import android.content.Context
import android.net.Uri
import android.os.StatFs
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Read-ahead to storage for large direct-play files (Jellyfin `/Videos/{id}/stream?static=true`).
 *
 * The player's own buffer lives in RAM and is capped (32-80 MB on 1.5-2 GB TVs, i.e. ~10-20 s of
 * a 27 GB remux). Here a background downloader fetches the file AHEAD of the playhead into a disk
 * cache, in 16 MB pieces over up to [PARALLEL] connections at once (one TCP connection often can't
 * use a long-distance line fully). The player reads through [CacheDataSource], so whatever has
 * been fetched comes from local storage instantly and network dips are ridden out.
 *
 * Live / HLS / IPTV streams never use this (see [isEligible]).
 */
@UnstableApi
object ReadAhead {
    private const val TAG = "VoltixReadAhead"
    private const val MB = 1024L * 1024L
    // Small pieces, many at once: a single connection to a distant/slow server
    // gets ~8-12 Mbps however fast the line is, so a 4K file (50-80 Mbps) only
    // starts when several connections fill the cache in parallel.
    /**
     * Master switch. OFF: the player reads straight from the server exactly like
     * the official Jellyfin app (which starts the same 4K titles quickly on
     * supersilo) - no on-disk cache, no parallel downloads. Turn back on only
     * if a test shows read-ahead helps on a given server.
     */
    // ON again, but only AFTER the picture has started (see Media3VideoView
    // .startReadAhead): it no longer touches the start, it only keeps the next
    // minute or so on disk so a short slowdown of the server doesn't stall a
    // 4K film (the in-memory buffer is only ~10-15 s of 4K on a 384 MB heap).
    // OFF (priority: every 1080p stream must start). With it on, the player read
    // through a disk cache layer - a suspect for the 1080p hang at 0.9 s and the
    // NullPointerException in the loader after an audio change. Off, the player
    // reads straight from the server exactly like the official Jellyfin app.
    // Now switched per source by the app (see [configureFor]): ON only for a 4K
    // film whose bitrate is above what one connection gives the TV, and only
    // when the admin switch "4K read-ahead" is on. Everything else (1080p,
    // live, HLS, IPTV) reads straight from the server as before.
    // test-connections.ps1 (supersilo): 1 conn 148 Mbps, 2 = 207, 4 = 357,
    // 6 = 522, no blocks - extra connections do add speed.
    @Volatile var enabled = false
        private set
    @Volatile private var enabledKey: String? = null

    const val CHUNK_BYTES = 8 * MB
    @Volatile var parallel = 3
        private set

    /** Turns read-ahead on for exactly this source ([connections] > 0), or off. */
    fun configureFor(url: String?, connections: Int) {
        if (url == null || connections <= 0) {
            enabled = false
            enabledKey = null
            return
        }
        parallel = connections.coerceIn(1, 6)
        enabledKey = try { keyFor(Uri.parse(url)) } catch (_: Throwable) { null }
        enabled = enabledKey != null
        android.util.Log.i(TAG, "On for this source with $parallel connections")
    }

    @Volatile private var cache: SimpleCache? = null
    @Volatile private var initTried = false
    @Volatile var windowBytes: Long = 0L
        private set

    /** Shared on-disk cache, or null when the device is short on storage. */
    @Synchronized
    fun cache(context: Context): SimpleCache? {
        if (!enabled) return null
        if (initTried) return cache
        initTried = true
        return try {
            val dir = File(context.cacheDir, "voltix-readahead")
            dir.mkdirs()
            val free = StatFs(dir.path).availableBytes
            if (free < 768 * MB) {
                android.util.Log.i(TAG, "Disabled: only ${free / MB} MB free")
                null
            } else {
                val size = (free / 4).coerceIn(256 * MB, 2048 * MB)
                windowBytes = (size / 2).coerceAtMost(600 * MB)
                android.util.Log.i(TAG, "Cache ${size / MB} MB, read-ahead window ${windowBytes / MB} MB")
                SimpleCache(
                    dir,
                    LeastRecentlyUsedCacheEvictor(size),
                    StandaloneDatabaseProvider(context),
                ).also { cache = it }
            }
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "Disabled: ${t.message}")
            null
        }
    }

    /** Cache-backed source for [cache] (token-free keys; falls back to network on cache errors). */
    fun cacheFactory(cache: SimpleCache, upstream: DataSource.Factory): CacheDataSource.Factory =
        CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstream)
            .setCacheKeyFactory(keyFactory)
            // BLOCK_ON_CACHE: when the piece the player needs is being downloaded
            // by a read-ahead connection, wait for it instead of fetching the same
            // bytes a second time over one slow connection.
            // No BLOCK_ON_CACHE: the player never waits on a read-ahead piece;
            // if one is still downloading it simply reads those bytes itself.
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

    /** Jellyfin direct-play (static) file over http(s); never live, HLS or IPTV. */
    fun isEligible(uri: Uri?): Boolean {
        if (!enabled || uri == null) return false
        val scheme = uri.scheme?.lowercase() ?: return false
        if (scheme != "http" && scheme != "https") return false
        val path = uri.path?.lowercase() ?: return false
        if (path.endsWith(".m3u8") || path.endsWith(".ts") || path.contains("/live/")) return false
        val isStatic = uri.getQueryParameter("static")?.equals("true", ignoreCase = true) == true ||
            uri.getQueryParameter("Static")?.equals("true", ignoreCase = true) == true
        return isStatic && path.contains("/videos/") && path.contains("/stream") &&
            enabledKey == keyFor(uri)
    }

    /** Cache key without the auth token, so a refreshed token keeps the cached bytes. */
    val keyFactory = CacheKeyFactory { spec -> keyFor(spec.uri) }

    fun keyFor(uri: Uri): String {
        val b = uri.buildUpon().clearQuery()
        for (name in uri.queryParameterNames) {
            if (name.equals("api_key", true) || name.equals("ApiKey", true) ||
                name.equals("X-Emby-Token", true) || name.equals("r", true)
            ) continue
            for (v in uri.getQueryParameters(name)) b.appendQueryParameter(name, v)
        }
        return b.build().toString()
    }

    /**
     * What the PLAYER reads through: pieces the read-ahead already fetched come
     * from storage, everything else straight from the network WITHOUT being
     * written to storage. Writing every byte the player streams to a TV's slow
     * flash memory (on top of the read-ahead writes) can itself hold a 70 Mbps
     * stream back; the official Jellyfin app writes nothing to storage.
     */
    fun playerCacheFactory(cache: SimpleCache, upstream: DataSource.Factory): CacheDataSource.Factory =
        CacheDataSource.Factory()
            .setCache(cache)
            .setUpstreamDataSourceFactory(upstream)
            .setCacheWriteDataSinkFactory(null)
            .setCacheKeyFactory(keyFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

    /** Routes eligible files through the cache, everything else straight to the network. */
    fun switchingFactory(plain: DataSource.Factory, cached: CacheDataSource.Factory): DataSource.Factory =
        DataSource.Factory { SwitchingDataSource(plain.createDataSource(), cached.createDataSource()) }

    private class SwitchingDataSource(
        private val plain: DataSource,
        private val cached: DataSource,
    ) : DataSource {
        private var active: DataSource? = null

        override fun addTransferListener(transferListener: TransferListener) {
            plain.addTransferListener(transferListener)
            cached.addTransferListener(transferListener)
        }

        override fun open(dataSpec: DataSpec): Long {
            val source = if (isEligible(dataSpec.uri)) cached else plain
            active = source
            return source.open(dataSpec)
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
            active?.read(buffer, offset, length) ?: throw IllegalStateException("Not opened")

        override fun getUri(): Uri? = active?.uri

        override fun getResponseHeaders(): Map<String, List<String>> =
            active?.responseHeaders ?: emptyMap()

        override fun close() {
            try {
                active?.close()
            } finally {
                active = null
            }
        }
    }

    /**
     * Keeps the [windowBytes] after the playhead downloaded. Call [start] for a new source,
     * [update] every couple of seconds with the playback position, [stop] when done.
     */
    class Prefetcher(
        private val cache: SimpleCache,
        private val factory: CacheDataSource.Factory,
        private val upstream: DataSource.Factory? = null,
    ) {
        @Volatile private var lengthProbeFor: String? = null

        /** File size from a 1-byte request (Content-Range: bytes 0-0/<size>), stored in the
         *  cache metadata. Needed because the player no longer writes to the cache, which is
         *  what used to record the size. */
        private fun probeLength(u: Uri, k: String) {
            val up = upstream ?: return
            if (lengthProbeFor == k) return
            lengthProbeFor = k
            try {
                pool.execute {
                    val ds = up.createDataSource()
                    try {
                        ds.open(DataSpec.Builder().setUri(u).setPosition(0).setLength(1).build())
                        val range = ds.responseHeaders.entries
                            .firstOrNull { it.key.equals("Content-Range", true) }
                            ?.value?.firstOrNull()
                        val total = range?.substringAfterLast('/')?.trim()?.toLongOrNull() ?: -1L
                        if (total > 0) {
                            val m = androidx.media3.datasource.cache.ContentMetadataMutations()
                            androidx.media3.datasource.cache.ContentMetadataMutations.setContentLength(m, total)
                            cache.applyContentMetadataMutations(k, m)
                        } else {
                            lengthProbeFor = null
                        }
                    } catch (_: Throwable) {
                        lengthProbeFor = null
                    } finally {
                        try { ds.close() } catch (_: Throwable) {}
                    }
                }
            } catch (_: Throwable) {
                lengthProbeFor = null
            }
        }

        private val pool: ExecutorService = Executors.newFixedThreadPool(parallel) { r ->
            Thread(r, "voltix-readahead").apply {
                isDaemon = true
                priority = Thread.NORM_PRIORITY - 1
            }
        }
        private val inFlight = ConcurrentHashMap<Long, CacheWriter>()
        @Volatile private var uri: Uri? = null
        @Volatile private var key: String? = null

        fun start(newUri: Uri) {
            // A different file means the previous one was stopped: delete its pieces.
            // The same file (player rebuilt mid-film) keeps them.
            val newKey = if (isEligible(newUri)) keyFor(newUri) else null
            stop(deleteCached = key != null && key != newKey)
            if (newKey == null) return
            uri = newUri
            key = keyFor(newUri)
            fetchedBytes.set(0)
            fetchStartedAtMs = android.os.SystemClock.elapsedRealtime()
        }

        private val fetchedBytes = java.util.concurrent.atomic.AtomicLong(0)
        @Volatile private var fetchStartedAtMs = 0L

        /** Read-ahead download speed (kbps) since this file started, and how many
         *  bytes after the playhead are already on disk. For the rebuffer report. */
        fun stats(positionMs: Long, durationMs: Long): Pair<Long, Long> {
            val k = key ?: return Pair(0L, 0L)
            val started = fetchStartedAtMs
            val elapsed = if (started > 0) android.os.SystemClock.elapsedRealtime() - started else 0L
            val kbps = if (elapsed > 1000) fetchedBytes.get() * 8 / elapsed else 0L
            val length = ContentMetadata.getContentLength(cache.getContentMetadata(k))
            if (length <= 0 || durationMs <= 0) return Pair(kbps, 0L)
            val playheadByte = (length.toDouble() * positionMs / durationMs).toLong().coerceIn(0, length)
            val ahead = try { cache.getCachedBytes(k, playheadByte, windowBytes) } catch (_: Throwable) { 0L }
            return Pair(kbps, ahead.coerceAtLeast(0L))
        }

        fun update(positionMs: Long, durationMs: Long, bufferedMs: Long = positionMs) {
            val u = uri ?: return
            val k = key ?: return
            if (positionMs < 0 || durationMs <= 0) return
            // Length is known once the player has opened the file through the cache.
            val length = ContentMetadata.getContentLength(cache.getContentMetadata(k))
            if (length <= 0) {
                probeLength(u, k)
                return
            }
            val window = windowBytes
            if (window <= 0) return

            val playheadByte = (length.toDouble() * positionMs / durationMs).toLong()
                .coerceIn(0, length)
            // Start where the player's own (in-memory) buffer ends: the bytes
            // between the playhead and there are already loaded, so fetching
            // them again only steals bandwidth from the player.
            val bufferedByte = (length.toDouble() * bufferedMs.coerceAtLeast(positionMs) / durationMs)
                .toLong().coerceIn(playheadByte, length)
            val first = (bufferedByte / CHUNK_BYTES).coerceAtLeast(0)
            val last = ((playheadByte + window).coerceAtMost(length - 1)) / CHUNK_BYTES

            // Drop work that is no longer around the playhead (after a seek).
            for ((chunk, writer) in inFlight) {
                if (chunk < first || chunk > last) {
                    writer.cancel()
                    inFlight.remove(chunk)
                }
            }

            // Nearest missing pieces first, at most PARALLEL downloads at a time.
            var chunk = first
            while (chunk <= last && inFlight.size < parallel) {
                val start = chunk * CHUNK_BYTES
                val len = minOf(CHUNK_BYTES, length - start)
                if (len > 0 && !inFlight.containsKey(chunk) && !cache.isCached(k, start, len)) {
                    submit(u, k, chunk, start, len)
                }
                chunk++
            }
        }

        private fun submit(u: Uri, k: String, chunk: Long, start: Long, len: Long) {
            val spec = DataSpec.Builder()
                .setUri(u)
                .setPosition(start)
                .setLength(len)
                .setKey(k)
                .setFlags(DataSpec.FLAG_ALLOW_CACHE_FRAGMENTATION)
                .build()
            val writer = CacheWriter(factory.createDataSourceForDownloading(), spec, null, null)
            inFlight[chunk] = writer
            try {
                pool.execute {
                    try {
                        writer.cache()
                        fetchedBytes.addAndGet(len)
                    } catch (_: Throwable) {
                        // Cancelled, or a network error: the player falls back to the network.
                    } finally {
                        inFlight.remove(chunk, writer)
                    }
                }
            } catch (_: Throwable) {
                inFlight.remove(chunk)
            }
        }

        /**
         * Stops reading ahead. With [deleteCached] the file's downloaded pieces are removed
         * from storage (playback stopped or finished); without it they are kept (player
         * rebuilt mid-film).
         */
        fun stop(deleteCached: Boolean = false) {
            val oldKey = key
            uri = null
            key = null
            for ((chunk, writer) in inFlight) {
                writer.cancel()
                inFlight.remove(chunk)
            }
            if (deleteCached && oldKey != null) deleteLater(oldKey)
        }

        fun shutdown(deleteCached: Boolean = false) {
            stop(deleteCached)
            pool.shutdownNow()
        }

        /** Removes a file's pieces once the player has let go of them. */
        private fun deleteLater(cacheKey: String) {
            Thread({
                try {
                    Thread.sleep(1_500)
                    cache.removeResource(cacheKey)
                    android.util.Log.i(TAG, "Removed read-ahead data for stopped/finished file")
                } catch (t: Throwable) {
                    android.util.Log.w(TAG, "Could not remove read-ahead data: ${t.message}")
                }
            }, "voltix-readahead-clean").apply { isDaemon = true }.start()
        }
    }
}
