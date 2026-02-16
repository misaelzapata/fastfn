package discovery

// Note: This package handles OpenApi spec aggregation from the discovered functions.
// In the current architecture, OpenResty generates the OpenAPI spec dynamically from the live routed endpoints.
// However, the CLI can also pre-generate a static spec for CI/CD or documentation purposes.

// For now, this is a placeholder to signify where the static generation logic will live.
// The actual dynamic generation happens in the Lua layer (OpenResty).
