exports.handler = async (event) => ({
  message: 'hello works',
  runtime: 'node',
  query: event.query || {},
});
