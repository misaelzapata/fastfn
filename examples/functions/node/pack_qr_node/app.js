const QRCode = require("qrcode");

exports.handler = async (event) => {
  const q = event.query || {};
  const text = q.text || "pack-qr-node";
  const png = await QRCode.toBuffer(text, { type: "png", width: 220, margin: 2 });
  return {
    status: 200,
    headers: { "Content-Type": "image/png" },
    is_base64: true,
    body_base64: png.toString("base64"),
  };
};
