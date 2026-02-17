// Metabase public embed URLs.
// Update these after enabling "Public Sharing" on each saved question in Metabase.
// The public link looks like: https://your-server/public/question/abc123-some-uuid

export const metabaseBaseUrl = 'METABASE_URL_PLACEHOLDER'

export const metabaseEmbeds = {
  priceComparison: `${metabaseBaseUrl}/public/question/UUID-HERE`,
  zoneStatistics: `${metabaseBaseUrl}/public/question/UUID-HERE`,
  optimizationRuns: `${metabaseBaseUrl}/public/question/UUID-HERE`,
}
