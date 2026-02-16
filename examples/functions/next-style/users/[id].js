exports.handler = async (event) => ({
  status: 200,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ route: '/users/:id', params: event.params || {}, runtime: 'node' }),
});
