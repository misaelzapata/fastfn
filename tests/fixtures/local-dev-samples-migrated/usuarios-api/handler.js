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
module.exports.handler = async (event, context) => {
  return {
    status: 200,
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      message: "Hello from FastFN Node!",
      input: event
    })
  };
};
