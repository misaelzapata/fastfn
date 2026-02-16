const { getState } = require('./_state');

exports.handler = async () => ({
  status: 200,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    route: 'GET /showcase/form',
    data: getState(),
    runtime: 'node',
  }),
});
