function asBool(value, fallback = true) {
  if (value === undefined || value === null) return fallback;
  if (typeof value === "boolean") return value;
  const normalized = String(value).trim().toLowerCase();
  return !["0", "false", "off", "no"].includes(normalized);
}

function json(status, payload) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
}

function parseJson(raw) {
  if (!raw) return null;
  if (typeof raw === "object" && !Array.isArray(raw)) return raw;
  if (typeof raw !== "string") return null;
  try {
    return JSON.parse(raw);
  } catch (_) {
    return null;
  }
}

function isUnsetSecret(value) {
  if (value === undefined || value === null) return true;
  const s = String(value).trim();
  if (!s) return true;
  const l = s.toLowerCase();
  return l === "<set-me>" || l === "set-me" || l === "changeme" || l === "<changeme>" || l === "replace-me";
}

function chooseSecret(localValue, fallbackValue) {
  if (!isUnsetSecret(localValue)) return String(localValue).trim();
  if (!isUnsetSecret(fallbackValue)) return String(fallbackValue).trim();
  return "";
}

function getClientIp(event) {
  const headers = event.headers || {};
  const xff = headers["x-forwarded-for"] || headers["X-Forwarded-For"] || "";
  if (xff) return String(xff).split(",")[0].trim();
  if (event.client && event.client.ip) return String(event.client.ip);
  return null;
}

async function fetchText(url, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, timeoutMs || 8000));
  try {
    const res = await fetch(url, { method: "GET", signal: controller.signal });
    const raw = await res.text();
    return { ok: res.ok, status: res.status, raw };
  } catch (err) {
    return { ok: false, status: 0, raw: "", error: String(err && err.message ? err.message : err) };
  } finally {
    clearTimeout(timer);
  }
}

async function fetchJson(url, timeoutMs) {
  const res = await fetchText(url, timeoutMs);
  const parsed = parseJson(res.raw);
  return { ok: res.ok, status: res.status, data: parsed, raw: res.raw };
}

async function fetchIpInfo(ip, timeoutMs) {
  if (!ip) return null;
  const res = await fetchJson(`https://ipapi.co/${ip}/json/`, timeoutMs);
  if (!res.ok || !res.data) return null;
  const d = res.data;
  return {
    ip,
    country: d.country_name || d.country || null,
    country_code: d.country_code || d.country || null,
    region: d.region || d.region_code || null,
    city: d.city || null,
    lat: d.latitude || d.lat || null,
    lon: d.longitude || d.lon || null,
    timezone: d.timezone || null,
  };
}

function weatherCodeToText(code) {
  const map = {
    0: "clear",
    1: "mainly clear",
    2: "partly cloudy",
    3: "overcast",
    45: "fog",
    48: "depositing rime fog",
    51: "light drizzle",
    53: "moderate drizzle",
    55: "dense drizzle",
    61: "slight rain",
    63: "moderate rain",
    65: "heavy rain",
    71: "slight snow",
    73: "moderate snow",
    75: "heavy snow",
    80: "rain showers",
    81: "heavy rain showers",
    82: "violent rain showers",
    95: "thunderstorm",
  };
  return map[code] || "unknown";
}

async function fetchWeather(lat, lon, timeoutMs) {
  if (lat == null || lon == null) return null;
  const url = `https://api.open-meteo.com/v1/forecast?latitude=${encodeURIComponent(lat)}&longitude=${encodeURIComponent(lon)}&current=temperature_2m,weather_code,wind_speed_10m&timezone=auto`;
  const res = await fetchJson(url, timeoutMs);
  if (!res.ok || !res.data || !res.data.current) return null;
  const c = res.data.current;
  return {
    temperature_c: c.temperature_2m,
    wind_kmh: c.wind_speed_10m,
    weather_code: c.weather_code,
    weather_text: weatherCodeToText(c.weather_code),
  };
}

function countryToNewsLocale(code) {
  const c = (code || "").toUpperCase();
  const esCountries = new Set(["AR","MX","ES","CO","CL","PE","UY","PY","BO","EC","VE","GT","HN","NI","CR","PA","DO","SV","PR"]);
  if (esCountries.has(c)) return { hl: "es-419", gl: c, ceid: `${c}:es-419` };
  if (!c) return { hl: "en-US", gl: "US", ceid: "US:en" };
  return { hl: "en-US", gl: c, ceid: `${c}:en` };
}

function parseRssItems(xml, maxItems) {
  if (!xml) return [];
  const items = [];
  const itemRe = /<item>[\s\S]*?<\/item>/gi;
  const titleRe = /<title>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>/i;
  const linkRe = /<link>([^<]+)<\/link>/i;
  let match;
  while ((match = itemRe.exec(xml)) && items.length < maxItems) {
    const chunk = match[0];
    const titleMatch = titleRe.exec(chunk);
    const linkMatch = linkRe.exec(chunk);
    const title = titleMatch ? titleMatch[1].trim() : null;
    const link = linkMatch ? linkMatch[1].trim() : null;
    if (title && link) {
      items.push({ title, link });
    }
  }
  return items;
}

function escapeHtml(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function lastSendPath() {
  return process.env.FASTFN_DIGEST_STATE || require("path").join(__dirname, ".last_sent.json");
}

function lockPath() {
  return lastSendPath() + ".lock";
}

function tryAcquireRunLock(maxAgeSecs) {
  const fs = require("fs");
  const path = lockPath();
  const now = Date.now();

  local_try:
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = fs.openSync(path, "wx");
      fs.writeFileSync(fd, JSON.stringify({ ts: now, pid: process.pid }));
      return { path, fd };
    } catch (err) {
      if (!err || err.code !== "EEXIST") {
        return null;
      }
      try {
        const raw = fs.readFileSync(path, "utf8");
        const parsed = parseJson(raw) || {};
        const ts = Number(parsed.ts || 0);
        if (ts > 0 && (now - ts) / 1000 > Math.max(10, Number(maxAgeSecs || 120))) {
          fs.unlinkSync(path);
          continue local_try;
        }
      } catch (_) {
        try {
          fs.unlinkSync(path);
          continue local_try;
        } catch (__e) {
          return null;
        }
      }
      return null;
    }
  }
  return null;
}

function releaseRunLock(lock) {
  if (!lock) return;
  const fs = require("fs");
  try {
    if (typeof lock.fd === "number") fs.closeSync(lock.fd);
  } catch (_) {
    // ignore
  }
  try {
    if (lock.path) fs.unlinkSync(lock.path);
  } catch (_) {
    // ignore
  }
}

function readLastSent() {
  const fs = require("fs");
  const path = lastSendPath();
  try {
    const raw = fs.readFileSync(path, "utf8");
    const parsed = parseJson(raw);
    if (parsed && typeof parsed.ts === "number") return parsed.ts;
  } catch (_) {
    return 0;
  }
  return 0;
}

function writeLastSent(ts) {
  const fs = require("fs");
  const path = lastSendPath();
  try {
    fs.writeFileSync(path, JSON.stringify({ ts }, null, 2));
  } catch (_) {
    // ignore
  }
}

async function fetchNews(countryCode, timeoutMs, maxItems) {
  const locale = countryToNewsLocale(countryCode);
  const url = `https://news.google.com/rss?hl=${locale.hl}&gl=${locale.gl}&ceid=${locale.ceid}`;
  const res = await fetchText(url, timeoutMs);
  if (!res.ok) return null;
  const items = parseRssItems(res.raw, maxItems);
  return { source: "google-news-rss", items, locale };
}

async function openaiDigest(env, text, timeoutMs, language) {
  const apiKey = chooseSecret(env.OPENAI_API_KEY, process.env.OPENAI_API_KEY);
  if (!apiKey) return null;
  const baseUrl = String(env.OPENAI_BASE_URL || process.env.OPENAI_BASE_URL || "https://api.openai.com/v1").replace(/\/+$/, "");
  const model = String(env.OPENAI_MODEL || process.env.OPENAI_MODEL || "gpt-4o-mini");
  const system = language === "es"
    ? "Eres un asistente conciso. Devuelve un resumen breve con viñetas y una recomendación corta."
    : "You are concise. Return a short summary with bullets and one short recommendation.";

  const payload = {
    model,
    messages: [
      { role: "system", content: system },
      { role: "user", content: text },
    ],
  };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1, timeoutMs || 8000));
  try {
    const res = await fetch(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const raw = await res.text();
    if (!res.ok) return null;
    const parsed = parseJson(raw);
    const textOut = parsed && parsed.choices && parsed.choices[0] && parsed.choices[0].message && parsed.choices[0].message.content;
    return textOut || null;
  } catch (_) {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function telegramSend(env, chatId, text, parseMode) {
  const token = chooseSecret(env.TELEGRAM_BOT_TOKEN, process.env.TELEGRAM_BOT_TOKEN);
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN not configured");
  const apiBase = String(env.TELEGRAM_API_BASE || process.env.TELEGRAM_API_BASE || "https://api.telegram.org").replace(/\/+$/, "");

  const body = {
    chat_id: String(chatId),
    text: String(text || ""),
  };
  if (parseMode) body.parse_mode = parseMode;

  let res = await fetch(`${apiBase}/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  let raw = await res.text();
  let parsed = parseJson(raw) || { raw };
  if (!res.ok || parsed.ok !== true) {
    // Fallback to plain text if parse mode fails.
    if (res.status === 400 && typeof raw === "string") {
      const bodyPlain = {
        chat_id: String(chatId),
        text: String(text || ""),
      };
      res = await fetch(`${apiBase}/bot${token}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(bodyPlain),
      });
      raw = await res.text();
      parsed = parseJson(raw) || { raw };
    }
  }
  if (!res.ok || parsed.ok !== true) {
    throw new Error(`telegram send failed status=${res.status} body=${raw}`);
  }
  return parsed;
}

module.exports = {
  asBool,
  json,
  parseJson,
  isUnsetSecret,
  chooseSecret,
  getClientIp,
  fetchText,
  fetchJson,
  fetchIpInfo,
  weatherCodeToText,
  fetchWeather,
  countryToNewsLocale,
  parseRssItems,
  escapeHtml,
  lastSendPath,
  lockPath,
  tryAcquireRunLock,
  releaseRunLock,
  readLastSent,
  writeLastSent,
  fetchNews,
  openaiDigest,
  telegramSend
};
