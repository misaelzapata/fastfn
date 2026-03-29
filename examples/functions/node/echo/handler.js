exports.handler = async (event) => {
  const query = event.query || {};
  const context = event.context || {};
  const key = query.key ?? null;
  return {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      key,
      query,
      context: {
        user: context.user || null,
      },
    }),
  };
};
