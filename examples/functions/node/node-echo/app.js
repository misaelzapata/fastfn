exports.handler = async (event) => {
  const query = event.query || {};
  const name = query.name || 'world';
  return {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ runtime: 'node', function: 'node-echo', hello: name }),
  };
};
