const { json, buildUserDetailPayload } = require("./_shared");

exports.handler = async (event) => json(buildUserDetailPayload(event.params || {}));
