const { makeUpsertHandler } = require('./_upsert');

exports.handler = makeUpsertHandler('PUT');
