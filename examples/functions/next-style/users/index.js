const { json, buildUsersIndexPayload } = require("./_shared");

exports.handler = async () => json(buildUsersIndexPayload());
