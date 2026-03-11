exports.handler = function(event) {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      version: "v1",
      users: [
        { id: 1, name: "Alice" },
        { id: 2, name: "Bob" },
      ],
    }),
  };
};
