// @summary Scheduled Telegram digest (weather + news) with AI
// @methods GET,POST
// @query {"chat_id":"123","dry_run":"true"}

const {
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
} = require("./_internal");

exports.handler = async (event) => {
  const env = event.env || {};
  const ctx = event.context || {};
  const query = event.query || {};
  const body = parseJson(event.body) || {};

  const dryRun = asBool(query.dry_run ?? body.dry_run, true);
  const preview = asBool(query.preview ?? body.preview, false);
  const chatId = query.chat_id || body.chat_id || env.TELEGRAM_CHAT_ID || process.env.TELEGRAM_CHAT_ID;
  const includeWeather = asBool(query.include_weather ?? body.include_weather, true);
  const includeNews = asBool(query.include_news ?? body.include_news, true);
  const includeAi = asBool(query.include_ai ?? body.include_ai, false);
  const minIntervalRaw = Number(query.min_interval_secs || body.min_interval_secs || 60);
  const minIntervalSecs = Math.max(0, Math.min(86400, Number.isFinite(minIntervalRaw) ? minIntervalRaw : 60));
  const maxItems = Math.max(1, Math.min(10, Number(query.max_items || body.max_items || 5)));
  const clientIp = getClientIp(event);

  if (!preview && !chatId) {
    return json(400, { error: "chat_id is required (or set TELEGRAM_CHAT_ID)" });
  }

  if (dryRun && !preview) {
    return json(200, {
      ok: true,
      dry_run: true,
      chat_id: chatId,
      note: "Set ?dry_run=false to send the digest to Telegram.",
    });
  }

  try {
    const lock = preview ? null : tryAcquireRunLock(Number(query.lock_ttl_secs || body.lock_ttl_secs || 120));
    if (!preview && !lock) {
      return json(200, {
        ok: true,
        skipped: true,
        reason: "in_progress",
      });
    }

    try {
    const lastSent = readLastSent();
    const nowTs = Date.now();
    if (!preview && lastSent > 0 && (nowTs - lastSent) / 1000 < minIntervalSecs) {
      return json(200, {
        ok: true,
        skipped: true,
        reason: "min_interval_secs",
        next_allowed_in: Math.ceil(minIntervalSecs - (nowTs - lastSent) / 1000),
      });
    }

    const timeoutMs = Math.min(15000, ctx.timeout_ms || 8000);
    const ipInfo = await fetchIpInfo(clientIp, timeoutMs);
    const countryCode = ipInfo && ipInfo.country_code ? String(ipInfo.country_code) : "";
    const language = countryCode && countryToNewsLocale(countryCode).hl.startsWith("es") ? "es" : "en";

    const warnings = [];
    let weather = null;
    if (includeWeather && ipInfo && ipInfo.lat != null && ipInfo.lon != null) {
      weather = await fetchWeather(ipInfo.lat, ipInfo.lon, timeoutMs);
      if (!weather) warnings.push("weather_unavailable");
    }

    let news = null;
    if (includeNews) {
      news = await fetchNews(countryCode, timeoutMs, maxItems);
      if (!news) warnings.push("news_unavailable");
    }

    const lines = [];
    const now = new Date().toISOString().slice(0, 16).replace("T", " ");
    if (language === "es") {
      lines.push(`<b>Digest diario</b> (${escapeHtml(now)} UTC)`);
      if (ipInfo) {
        const loc = `${ipInfo.city || ""} ${ipInfo.country || ""}`.trim();
        if (loc) lines.push(`<b>Ubicación:</b> ${escapeHtml(loc)}`);
      }
      if (weather) lines.push(`<b>Clima:</b> ${escapeHtml(String(weather.temperature_c))}°C, ${escapeHtml(weather.weather_text)}, viento ${escapeHtml(String(weather.wind_kmh))} km/h`);
      if (news && news.items.length) {
        lines.push("<b>Titulares:</b>");
        news.items.forEach((item, idx) => {
          const title = escapeHtml(item.title);
          const link = escapeHtml(item.link);
          lines.push(`${idx + 1}. <a href="${link}">${title}</a>`);
        });
      }
    } else {
      lines.push(`<b>Daily Digest</b> (${escapeHtml(now)} UTC)`);
      if (ipInfo) {
        const loc = `${ipInfo.city || ""} ${ipInfo.country || ""}`.trim();
        if (loc) lines.push(`<b>Location:</b> ${escapeHtml(loc)}`);
      }
      if (weather) lines.push(`<b>Weather:</b> ${escapeHtml(String(weather.temperature_c))}°C, ${escapeHtml(weather.weather_text)}, wind ${escapeHtml(String(weather.wind_kmh))} km/h`);
      if (news && news.items.length) {
        lines.push("<b>Headlines:</b>");
        news.items.forEach((item, idx) => {
          const title = escapeHtml(item.title);
          const link = escapeHtml(item.link);
          lines.push(`${idx + 1}. <a href="${link}">${title}</a>`);
        });
      }
    }

    const rawText = lines.join("\n");
    const aiText = includeAi ? await openaiDigest(env, rawText, timeoutMs, language) : null;
    const message = aiText
      ? rawText + "\n\n<b>IA:</b>\n" + escapeHtml(aiText)
      : rawText;

    if (preview) {
      return json(200, {
        ok: true,
        preview: true,
        used_ai: !!aiText,
        warnings,
        message,
      });
    }

    const sent = await telegramSend(env, chatId, message, "HTML");
    writeLastSent(nowTs);
    return json(200, {
      ok: true,
      dry_run: false,
      chat_id: chatId,
      used_ai: !!aiText,
      warnings,
      telegram: { message_id: sent.result && sent.result.message_id },
      preview: message,
    });
    } finally {
      releaseRunLock(lock);
    }
  } catch (err) {
    return json(502, { error: String(err && err.message ? err.message : err) });
  }
};
