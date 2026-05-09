import type { Command } from '../commands.js'
import type { MCPServerConnection } from '../services/mcp/types.js'
import { memoizeWithLRU } from '../utils/memoize.js'

const MCP_FETCH_CACHE_SIZE = 20

/**
 * Minimal fallback for the feature-gated MCP skills module.
 *
 * The public source references this module behind feature('MCP_SKILLS'), but
 * the original implementation is not present in this source drop. Returning an
 * empty list preserves current behavior while keeping the import resolvable if
 * the feature gate is enabled in a local build.
 */
export const fetchMcpSkillsForClient = memoizeWithLRU(
  async (_client: MCPServerConnection): Promise<Command[]> => [],
  client => client.name,
  MCP_FETCH_CACHE_SIZE,
)
