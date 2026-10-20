/// One switch for the home-row / taste-profile query weight.
///
/// `true`  = FULL (original) queries: People/Tags look-ups for
///           recommendations, "More with actor" and "Rewatch" rows, rating-
///           sorted taste profile with cast, Random "More titles", uncapped
///           Next Up, and every heavy row re-queried on each refresh.
/// `false` = LITE queries tuned for a slow shared server (genre/rating only,
///           6-hour reuse of heavy rows, Next Up capped at 12, etc.).
///
/// Set to `true` to test how a server copes with the full load; flip back to
/// `false` and rebuild if it struggles.
const bool kFullHomeQueries = true;
