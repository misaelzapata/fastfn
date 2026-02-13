const { v4: uuidv4 } = require('uuid');

module.exports.handler = async (event, context) => {
  return {
    status: 200,
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      message: "Hello from Node with Deps!",
      uuid: uuidv4()
    })
  };
};
