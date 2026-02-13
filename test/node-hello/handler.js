module.exports.handler = async (event, context) => {
  return {
    status: 200,
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      message: "Hello from Node!",
      runtime: "node"
    })
  };
};
