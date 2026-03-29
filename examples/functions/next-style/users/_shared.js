function json(payload) {
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

function sharedMeta() {
  return {
    runtime: "node",
    helper: "users/_shared.js",
  };
}

function buildUsersIndexPayload() {
  return {
    route: "/users",
    ...sharedMeta(),
    users: [
      { id: "123", label: "Ada" },
      { id: "456", label: "Kai" },
    ],
  };
}

function buildUserDetailPayload(params) {
  return {
    route: "/users/:id",
    params: params || {},
    ...sharedMeta(),
  };
}

module.exports = {
  json,
  buildUsersIndexPayload,
  buildUserDetailPayload,
};
