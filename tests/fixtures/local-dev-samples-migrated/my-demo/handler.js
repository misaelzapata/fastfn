/**
 * @typedef {Object} Context
 * @property {string} requestId
 * @property {Object} headers
 */

/**
 * Handle the request.
 * @param {Object} event - The input event
 * @param {Context} context - The execution context
 * @returns {Promise<Object>} The response
 */
exports.handler = async (event, context) => {
  return {
    status: 200,
    body: {
      message: "Hello from FastFn!",
      input: event
    }
  };
};
