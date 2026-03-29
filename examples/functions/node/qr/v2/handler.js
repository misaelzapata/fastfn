// @summary Node QR generator (PNG)
// @methods GET
// @query {"text":"https://github.com/misaelzapata/fastfn"}
const QRCode = require('qrcode');

exports.handler = async (event) => {
  const query = event.query || {};
  const text = query.url || query.text || 'https://fastfn.io';
  const widthRaw = Number(query.size || 320);
  const width = Number.isFinite(widthRaw) ? Math.max(128, Math.min(1024, Math.floor(widthRaw))) : 320;

  const png = await QRCode.toBuffer(text, {
    type: 'png',
    width,
    margin: 2,
    errorCorrectionLevel: 'M',
  });

  return {
    status: 200,
    headers: {
      'Content-Type': 'image/png',
      'Cache-Control': 'no-store',
    },
    is_base64: true,
    body_base64: png.toString('base64'),
  };
};
