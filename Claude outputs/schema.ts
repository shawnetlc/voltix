import {
  boolean,
  decimal,
  int,
  mysqlEnum,
  mysqlTable,
  text,
  timestamp,
  varchar,
} from "drizzle-orm/mysql-core";

/**
 * Core user table backing auth flow.
 */
export const users = mysqlTable("users", {
  id: int("id").autoincrement().primaryKey(),
  openId: varchar("openId", { length: 64 }).notNull().unique(),
  /** Local auth: unique username (e.g. voltix-admin). Null for OAuth-only users. */
  username: varchar("username", { length: 64 }).unique(),
  /** Bcrypt hash of the local password. Null for OAuth-only users. */
  passwordHash: text("passwordHash"),
  name: text("name"),
  email: varchar("email", { length: 320 }),
  loginMethod: varchar("loginMethod", { length: 64 }),
  role: mysqlEnum("role", ["user", "admin"]).default("user").notNull(),
  /**
   * The streaming account (`voltix_users.id`) belonging to this billing user.
   *
   * Exists because there is no foreign key anywhere in this schema, and code was
   * treating `users.id` AS a `voltix_users.id` - two independent autoincrement
   * sequences populated by unrelated events (registration, trial requests, admin
   * assignment, JIT login). They corresponded only by coincidence, so a paid
   * subscription could provision an account against a different person's row.
   *
   * Nullable for rows that predate this column; resolveVoltixUserForBillingUser()
   * backfills it on first use by matching email, then username.
   */
  voltixUserId: int("voltixUserId"),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
  lastSignedIn: timestamp("lastSignedIn").defaultNow().notNull(),
});

export type User = typeof users.$inferSelect;
export type InsertUser = typeof users.$inferInsert;

// ─── Voltix subscriber accounts (Streaming Credentials) ──────────────────────
// These are the credentials users actually type in for the streaming app.
// Each user has SEPARATE Jellyfin credentials per server tier.
export const voltixUsers = mysqlTable("voltix_users", {
  id: int("id").autoincrement().primaryKey(),
  username: varchar("username", { length: 128 }).notNull().unique(),
  /** bcrypt hash of the user's Voltix password */
  passwordHash: varchar("passwordHash", { length: 255 }).notNull(),
  displayName: text("displayName"),
  email: varchar("email", { length: 320 }),
  /** Whether the subscription is currently active */
  isActive: boolean("isActive").default(true).notNull(),
  /** Fallback Jellyfin username (legacy / default) */
  jellyfinUsername: varchar("jellyfinUsername", { length: 255 }).notNull(),
  /** Fallback Jellyfin password (legacy / default) */
  jellyfinPassword: varchar("jellyfinPassword", { length: 255 }).notNull(),
  /** Main server Jellyfin username */
  mainJellyfinUsername: varchar("mainJellyfinUsername", { length: 255 }),
  /** Main server Jellyfin password */
  mainJellyfinPassword: varchar("mainJellyfinPassword", { length: 255 }),
  /** Extra server Jellyfin username */
  extraJellyfinUsername: varchar("extraJellyfinUsername", { length: 255 }),
  /** Extra server Jellyfin password */
  extraJellyfinPassword: varchar("extraJellyfinPassword", { length: 255 }),
  /** 4K server Jellyfin username */
  fourKJellyfinUsername: varchar("fourKJellyfinUsername", { length: 255 }),
  /** 4K server Jellyfin password */
  fourKJellyfinPassword: varchar("fourKJellyfinPassword", { length: 255 }),
  /** Which server this account primarily uses (optional convenience field) */
  primaryServerId: int("primaryServerId"),
  /** Max concurrent devices PER SERVER (default 1) */
  maxConcurrentDevices: int("maxConcurrentDevices").default(1).notNull(),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type VoltixUser = typeof voltixUsers.$inferSelect;
export type InsertVoltixUser = typeof voltixUsers.$inferInsert;

// ─── Pre-configured Jellyfin servers ─────────────────────────────────────────
export const servers = mysqlTable("servers", {
  id: int("id").autoincrement().primaryKey(),
  name: varchar("name", { length: 255 }).notNull(),
  url: varchar("url", { length: 512 }).notNull(),
  /** Display order */
  sortOrder: int("sortOrder").default(0).notNull(),
  isActive: boolean("isActive").default(true).notNull(),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
});

export type Server = typeof servers.$inferSelect;
export type InsertServer = typeof servers.$inferInsert;

// ─── User sessions (Streaming Sessions) ───────────────────────────────────────
export const voltixSessions = mysqlTable("voltix_sessions", {
  id: int("id").autoincrement().primaryKey(),
  voltixUserId: int("voltixUserId").notNull(),
  /** Opaque session token stored in a cookie */
  token: varchar("token", { length: 255 }).notNull().unique(),
  /** Human-readable device/browser name logged at login */
  deviceName: text("deviceName"),
  /** User-agent string for reference */
  userAgent: text("userAgent"),
  /** IP address at login time */
  ipAddress: varchar("ipAddress", { length: 64 }),
  /** Last time the subscription ping was received */
  lastPingAt: timestamp("lastPingAt").defaultNow().notNull(),
  /** Whether this session is still valid */
  isValid: boolean("isValid").default(true).notNull(),
  /** Jellyfin access token obtained server-side at login — never sent to client */
  jellyfinToken: varchar("jellyfinToken", { length: 512 }),
  /** Jellyfin user ID returned by the server at auth time */
  jellyfinUserId: varchar("jellyfinUserId", { length: 128 }),
  /** Which server this session authenticated against (FK to servers.id) */
  jellyfinServerId: int("jellyfinServerId"),
  /** When the Jellyfin token was last refreshed (used to schedule re-auth) */
  tokenRefreshedAt: timestamp("tokenRefreshedAt"),
  /** Voltix app version reported at login, refreshed on each ping — lets admin see who's on an old build */
  appVersion: varchar("appVersion", { length: 64 }),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  expiresAt: timestamp("expiresAt").notNull(),
});

export type VoltixSession = typeof voltixSessions.$inferSelect;
export type InsertVoltixSession = typeof voltixSessions.$inferInsert;

// ─── Device log (historical record of all devices ever used) ─────────────────
export const deviceLogs = mysqlTable("device_logs", {
  id: int("id").autoincrement().primaryKey(),
  voltixUserId: int("voltixUserId").notNull(),
  deviceName: text("deviceName"),
  userAgent: text("userAgent"),
  ipAddress: varchar("ipAddress", { length: 64 }),
  loggedAt: timestamp("loggedAt").defaultNow().notNull(),
});

export type DeviceLog = typeof deviceLogs.$inferSelect;

// Subscriptions table
export const subscriptions = mysqlTable("subscriptions", {
  id: varchar("id", { length: 64 }).primaryKey(),
  userId: int("userId").notNull(),
  planName: varchar("planName", { length: 64 }).notNull(), // "Single Stream" or "Family Bundle"
  duration: int("duration").notNull(), // months: 1, 3, or 6
  price: decimal("price", { precision: 10, scale: 2 }).notNull(),
  status: mysqlEnum("status", ["PENDING", "ACTIVE", "CANCELLED", "EXPIRED"]).default("PENDING").notNull(),
  paymentMethod: varchar("paymentMethod", { length: 32 }).default("EFT").notNull(),
  /**
   * Whether PayFast holds a recurring mandate for this subscription.
   *
   * Defaults to ONCE_OFF so every pre-existing row - and any future row written
   * by code that forgets to set this - reads as "no mandate". Guessing wrong in
   * that direction means a subscription that quietly stops; guessing the other
   * way would mean treating someone as recurring who never agreed to it.
   */
  billingMode: mysqlEnum("billingMode", ["ONCE_OFF", "RECURRING"]).default("ONCE_OFF").notNull(),
  payfastToken: text("payfastToken"),
  payfastPaymentId: varchar("payfastPaymentId", { length: 256 }),
  stitchPaymentId: varchar("stitchPaymentId", { length: 256 }),
  startDate: timestamp("startDate").defaultNow().notNull(),
  endDate: timestamp("endDate"),
  renewalDate: timestamp("renewalDate"),
  cancellationReason: text("cancellationReason"),
  cancellationFeedback: text("cancellationFeedback"),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type Subscription = typeof subscriptions.$inferSelect;
export type InsertSubscription = typeof subscriptions.$inferInsert;

// Trials table
export const trials = mysqlTable("trials", {
  id: varchar("id", { length: 64 }).primaryKey(),
  name: varchar("name", { length: 255 }).notNull(),
  email: varchar("email", { length: 320 }).notNull(),
  status: mysqlEnum("status", ["PENDING", "APPROVED", "REJECTED", "EXPIRED", "DATA_WIPED"])
    .default("PENDING")
    .notNull(),
  jellyfinUsername: varchar("jellyfinUsername", { length: 255 }),
  jellyfinPassword: text("jellyfinPassword"),
  streamingAccountId: varchar("streamingAccountId", { length: 64 }),
  /**
   * IPTV account reserved for this trial.
   *
   * Set when the trial is REQUESTED, not when it is approved, so that the
   * connection is accounted for immediately and two simultaneous requests cannot
   * be handed the same one. The admin can change it before approving.
   */
  iptvAccountId: varchar("iptvAccountId", { length: 64 }),
  /**
   * The Voltix app login created for this trial. The account exists from the
   * moment of request but stays inactive until an admin approves, so the
   * credentials can be prepared without granting access.
   */
  voltixUserId: int("voltixUserId"),
  reminderSent: boolean("reminderSent").default(false).notNull(),
  startDate: timestamp("startDate"),
  endDate: timestamp("endDate"),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type Trial = typeof trials.$inferSelect;
export type InsertTrial = typeof trials.$inferInsert;

// Streaming Accounts table (Jellyfin accounts)
export const streamingAccounts = mysqlTable("streaming_accounts", {
  id: varchar("id", { length: 64 }).primaryKey(),
  jellyfinUsername: varchar("jellyfinUsername", { length: 255 }).notNull().unique(),
  jellyfinPassword: text("jellyfinPassword").notNull(),
  jellyfinUserId: varchar("jellyfinUserId", { length: 255 }),
  assignedToUserId: int("assignedToUserId"),
  mainServerUrl: varchar("mainServerUrl", { length: 512 }).default("https://main.lumistream.cc"),
  extraServerUrl: varchar("extraServerUrl", { length: 512 }).default("https://extra.lumistream.cc"),
  server_4k_url: varchar("server_4k_url", { length: 512 }).default("https://4k.lumistream.cc"),
  isAssigned: boolean("isAssigned").default(false),
  isMainUser: boolean("isMainUser").default(false),
  tag: varchar("tag", { length: 32 }).default("Lite"), // "Pro+", "Pro", "Lite", "Sub-Account"
  /** Total connection pool size for this account across all assigned users */
  maxConnections: int("maxConnections").default(5).notNull(),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type StreamingAccount = typeof streamingAccounts.$inferSelect;
export type InsertStreamingAccount = typeof streamingAccounts.$inferInsert;

export const streamingAccountAssignments = mysqlTable("streaming_account_assignments", {
  id: int("id").autoincrement().primaryKey(),
  streamingAccountId: varchar("streamingAccountId", { length: 64 }).notNull(),
  voltixUserId: int("voltixUserId").notNull(),
  /** How many connections this user may use on Main server from this pool */
  maxConnectionsMain: int("maxConnectionsMain").default(1).notNull(),
  /** How many connections this user may use on Extra server from this pool */
  maxConnectionsExtra: int("maxConnectionsExtra").default(1).notNull(),
  /** How many connections this user may use on 4K server from this pool */
  maxConnections4K: int("maxConnections4K").default(1).notNull(),
  assignedAt: timestamp("assignedAt").defaultNow().notNull(),
});

export type StreamingAccountAssignment = typeof streamingAccountAssignments.$inferSelect;
export type InsertStreamingAccountAssignment = typeof streamingAccountAssignments.$inferInsert;

// Payment Transactions table
export const paymentTransactions = mysqlTable("payment_transactions", {
  id: varchar("id", { length: 64 }).primaryKey(),
  subscriptionId: varchar("subscriptionId", { length: 64 }).notNull(),
  userId: int("userId").notNull(),
  amount: decimal("amount", { precision: 10, scale: 2 }).notNull(),
  currency: varchar("currency", { length: 3 }).default("ZAR"),
  paymentMethod: varchar("paymentMethod", { length: 32 }).notNull(),
  payfastPaymentId: varchar("payfastPaymentId", { length: 256 }),
  stitchPaymentId: varchar("stitchPaymentId", { length: 256 }),
  status: mysqlEnum("status", ["PENDING", "COMPLETED", "FAILED", "REFUNDED"])
    .default("PENDING")
    .notNull(),
  reference: varchar("reference", { length: 256 }),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type PaymentTransaction = typeof paymentTransactions.$inferSelect;
export type InsertPaymentTransaction = typeof paymentTransactions.$inferInsert;

// ─── Global Settings ────────────────────────────────────────────────────────
export const settings = mysqlTable("settings", {
  id: int("id").autoincrement().primaryKey(),
  key: varchar("key", { length: 255 }).notNull().unique(),
  value: text("value").notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type Setting = typeof settings.$inferSelect;
export type InsertSetting = typeof settings.$inferInsert;

// ─── IPTV Accounts (Xtream Codes credential pool) ────────────────────────────
export const iptvAccounts = mysqlTable("iptv_accounts", {
  id: varchar("id", { length: 64 }).primaryKey(),
  /** Friendly label, e.g. "Provider A – Slot 1" */
  name: varchar("name", { length: 255 }).notNull(),
  /** Xtream Codes server URL, e.g. http://iptv.example.com:8080 */
  serverUrl: varchar("serverUrl", { length: 512 }).notNull(),
  /** Xtream Codes username */
  username: varchar("username", { length: 255 }).notNull(),
  /** Xtream Codes password */
  password: varchar("password", { length: 255 }).notNull(),
  /** The raw M3U URL used to configure the account (optional) */
  m3uUrl: text("m3uUrl"),
  /** Whether this account is currently assigned to a user */
  isAssigned: boolean("isAssigned").default(false),
  /** Max simultaneous connections allowed by the provider */
  maxConnections: int("maxConnections").default(1).notNull(),
  /** Default IPTV package for users on this account: 'standard' (HD+FHD), 'premium' (all), 'basic' (SD) */
  iptvPackage: varchar("iptvPackage", { length: 32 }).default("standard").notNull(),
  /** Server role for multi-server search: 'primary', '4k', 'extra' */
  serverRole: varchar("serverRole", { length: 32 }).default("primary").notNull(),
  /** MAC address / Device ID assigned to this account for device-based auth (optional) */
  macAddress: varchar("macAddress", { length: 64 }),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type IptvAccount = typeof iptvAccounts.$inferSelect;
export type InsertIptvAccount = typeof iptvAccounts.$inferInsert;

// ─── IPTV Account Assignments ─────────────────────────────────────────────────
export const iptvAssignments = mysqlTable("iptv_assignments", {
  id: int("id").autoincrement().primaryKey(),
  iptvAccountId: varchar("iptvAccountId", { length: 64 }).notNull(),
  voltixUserId: int("voltixUserId").notNull(),
  /** Per-user package override. NULL = use the account's default iptvPackage */
  iptvPackage: varchar("iptvPackage", { length: 32 }),
  assignedAt: timestamp("assignedAt").defaultNow().notNull(),
});

export type IptvAssignment = typeof iptvAssignments.$inferSelect;
export type InsertIptvAssignment = typeof iptvAssignments.$inferInsert;

// ─── IPTV Favorites ──────────────────────────────────────────────────────────
export const iptvFavorites = mysqlTable("iptv_favorites", {
  id: int("id").autoincrement().primaryKey(),
  voltixUserId: int("voltixUserId").notNull(),
  type: varchar("type", { length: 32 }).notNull(), // 'live' | 'vod' | 'series'
  itemId: varchar("itemId", { length: 255 }).notNull(),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
});

export type IptvFavorite = typeof iptvFavorites.$inferSelect;
export type InsertIptvFavorite = typeof iptvFavorites.$inferInsert;

// ─── IPTV Watch Progress ─────────────────────────────────────────────────────
export const iptvWatchProgress = mysqlTable("iptv_watch_progress", {
  id: int("id").autoincrement().primaryKey(),
  voltixUserId: int("voltixUserId").notNull(),
  type: varchar("type", { length: 32 }).notNull(), // 'vod' | 'series_episode'
  itemId: varchar("itemId", { length: 255 }).notNull(),
  seriesId: varchar("seriesId", { length: 255 }),
  seasonNumber: int("seasonNumber"),
  episodeNumber: int("episodeNumber"),
  currentTime: decimal("currentTime", { precision: 12, scale: 3 }).notNull().default("0.000"),
  totalDuration: decimal("totalDuration", { precision: 12, scale: 3 }).notNull().default("0.000"),
  isWatched: boolean("isWatched").default(false).notNull(),
  needsTranscode: boolean("needsTranscode").default(false).notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type IptvWatchProgressSelect = typeof iptvWatchProgress.$inferSelect;
export type InsertIptvWatchProgress = typeof iptvWatchProgress.$inferInsert;

// ─── IPTV Preferences ────────────────────────────────────────────────────────
export const iptvPreferences = mysqlTable("iptv_preferences", {
  voltixUserId: int("voltixUserId").primaryKey(),
  autoplay: boolean("autoplay").default(true).notNull(),
  language: varchar("language", { length: 10 }).default("fr").notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type IptvPreference = typeof iptvPreferences.$inferSelect;
export type InsertIptvPreference = typeof iptvPreferences.$inferInsert;

// ─── Device Pairing Codes (Plex-style /link) ─────────────────────────────────
export const voltixPairingCodes = mysqlTable("voltix_pairing_codes", {
  id: int("id").autoincrement().primaryKey(),
  code: varchar("code", { length: 6 }).notNull().unique(), // The 4-6 char pairing code (e.g. ABCD)
  deviceName: varchar("deviceName", { length: 255 }), // Name of device requesting linking
  deviceCode: varchar("deviceCode", { length: 128 }).notNull(), // Unique device ID/code generated by client
  voltixSessionToken: varchar("voltixSessionToken", { length: 255 }), // Populated when approved
  status: varchar("status", { length: 32 }).default("PENDING").notNull(), // PENDING, APPROVED, EXPIRED
  expiresAt: timestamp("expiresAt").notNull(),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type VoltixPairingCode = typeof voltixPairingCodes.$inferSelect;
export type InsertVoltixPairingCode = typeof voltixPairingCodes.$inferInsert;

// ─── Voltix User App Settings (Cloud Settings Sync & Azure Storage) ──────────
export const voltixUserSettings = mysqlTable("voltix_user_settings", {
  id: int("id").autoincrement().primaryKey(),
  username: varchar("username", { length: 128 }).notNull().unique(),
  settingsJson: text("settingsJson").notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type VoltixUserSettings = typeof voltixUserSettings.$inferSelect;
export type InsertVoltixUserSettings = typeof voltixUserSettings.$inferInsert;

// ─── Push Notification Devices (FCM tokens registered from mobile/app/web) ───
export const pushDevices = mysqlTable("push_devices", {
  id: int("id").autoincrement().primaryKey(),
  token: varchar("token", { length: 512 }).notNull().unique(),
  userId: int("userId"),
  username: varchar("username", { length: 128 }),
  platform: varchar("platform", { length: 32 }).default("android").notNull(),
  deviceModel: varchar("deviceModel", { length: 128 }),
  appVersion: varchar("appVersion", { length: 64 }),
  isActive: boolean("isActive").default(true).notNull(),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
  lastSeenAt: timestamp("lastSeenAt").defaultNow().notNull(),
});

export type PushDevice = typeof pushDevices.$inferSelect;
export type InsertPushDevice = typeof pushDevices.$inferInsert;

// ─── Push Notification Broadcast History Log ─────────────────────────────────
export const pushNotifications = mysqlTable("push_notifications", {
  id: int("id").autoincrement().primaryKey(),
  title: varchar("title", { length: 255 }).notNull(),
  body: text("body").notNull(),
  imageUrl: text("imageUrl"),
  actionUrl: text("actionUrl"),
  targetType: varchar("targetType", { length: 32 }).default("all").notNull(),
  targetTopic: varchar("targetTopic", { length: 64 }).default("all").notNull(),
  targetPlatform: varchar("targetPlatform", { length: 32 }),
  status: varchar("status", { length: 32 }).default("sent").notNull(),
  successCount: int("successCount").default(0).notNull(),
  failureCount: int("failureCount").default(0).notNull(),
  errorMessage: text("errorMessage"),
  sentBy: varchar("sentBy", { length: 64 }),
  sentAt: timestamp("sentAt").defaultNow().notNull(),
  createdAt: timestamp("createdAt").defaultNow().notNull(),
});

export type PushNotification = typeof pushNotifications.$inferSelect;
export type InsertPushNotification = typeof pushNotifications.$inferInsert;

// ─── Programme Reminders ─────────────────────────────────────────────────────

/**
 * "Remind me" on a programme in the TV Guide.
 *
 * Everything the notification needs is copied in at the moment the reminder is
 * set — title, synopsis, artwork, channel, times. The EPG is a moving target:
 * schedules are revised, the XMLTV feed rolls forward and drops yesterday, and
 * artwork URLs are reissued. A reminder that stored only an id would have to go
 * looking at firing time and would sometimes find nothing, which is the one
 * moment it must not fail. This way the reminder is self-contained.
 */
export const programmeReminders = mysqlTable("programme_reminders", {
  id: int("id").autoincrement().primaryKey(),

  /** Voltix user who set it. Reminders fire to every device this user has. */
  voltixUserId: int("voltixUserId").notNull(),
  username: varchar("username", { length: 128 }),

  /** DStv channel, as the guide knows it — this is what the viewer is shown. */
  channelNumber: varchar("channelNumber", { length: 16 }),
  channelName: varchar("channelName", { length: 255 }).notNull(),

  /**
   * The PROVIDER's name for the same channel, which is what the app can search
   * the live list by.
   *
   * Both are needed and they are rarely the same string: the guide says
   * "SuperSport Grandstand" and the line-up says "ZA: SuperSport Grandstand HD".
   * The first is what the notification reads; the second is what tunes it.
   *
   * The name is stored rather than the stream id deliberately — ids are
   * reissued whenever a provider re-imports a line-up, so a reminder set last
   * week would tune to whatever happens to hold that id now.
   */
  providerChannelName: varchar("providerChannelName", { length: 255 }),

  /** Resolved at fire time rather than stored: line-ups change. */
  programmeTitle: varchar("programmeTitle", { length: 512 }).notNull(),
  programmeDescription: text("programmeDescription"),
  /** XMLTV artwork, shown as the notification image. */
  imageUrl: text("imageUrl"),

  /** Programme start and end, stored in UTC. */
  startsAt: timestamp("startsAt").notNull(),
  endsAt: timestamp("endsAt"),

  /** When the push should go out — start time minus the configured lead. */
  notifyAt: timestamp("notifyAt").notNull(),

  /**
   * PENDING until it fires, then SENT. FAILED when there was nothing to send
   * to, so a reminder cannot sit retrying for ever against a user who has no
   * registered device.
   */
  status: varchar("status", { length: 16 }).default("PENDING").notNull(),
  sentAt: timestamp("sentAt"),
  failureReason: varchar("failureReason", { length: 512 }),

  createdAt: timestamp("createdAt").defaultNow().notNull(),
  updatedAt: timestamp("updatedAt").defaultNow().onUpdateNow().notNull(),
});

export type ProgrammeReminder = typeof programmeReminders.$inferSelect;
export type InsertProgrammeReminder = typeof programmeReminders.$inferInsert;
