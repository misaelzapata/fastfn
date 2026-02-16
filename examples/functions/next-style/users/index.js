exports.handler = async () => ({
  status: 200,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ route: '/users', runtime: 'node' }),
});
