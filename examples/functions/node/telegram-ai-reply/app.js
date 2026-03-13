// @summary Telegram webhook -> OpenAI -> Telegram reply (AI bot)
// @methods POST
// @body {"message":{"chat":{"id":123},"text":"Hola"}}
//
// This is an end-to-end demo:
// - Receive Telegram webhook updates (POST JSON)
// - Generate a reply with OpenAI (Responses API)
// - Send the reply back via Telegram Bot API
//
// Safety:
// - dry_run defaults to true (set ?dry_run=false to really send)

const {
  asBool,
  json,
  logInteraction,
  parseJson,
  isTransientNetworkError,
  isUnsetSecret,
  chooseSecret,
  extractTelegram,
  extractResponsesText,
  sleep,
  withTransientRetry,
  fetchWithTimeout,
  telegramTimeoutMs,
  thinkingConfig,
  memoryConfig,
  toolConfig,
  parseToolDirectives,
  inferAutoTools,
  extractWeatherLocation,
  hostAllowed,
  isLocalHostname,
  canonicalSegment,
  executeTool,
  resolveToolContext,
  extractOpenAIMessageText,
  sanitizeLocation,
  planWeatherLocationWithAI,
  resolveAutoToolDirectives,
  memoryPath,
  loopStatePath,
  loopLockPath,
  tryAcquireLoopLock,
  releaseLoopLock,
  loadLoopState,
  saveLoopState,
  loadMemory,
  saveMemory,
  openaiGenerate,
  telegramGetUpdates,
  telegramDeleteWebhook,
  telegramSend,
  telegramSendTypingAction
} = require("./_internal");

exports.handler = async (event) => {
  const env = event.env || {};
  const ctx = event.context || {};
  const query = event.query || {};
  const isScheduledCall = !!(ctx && ctx.trigger && ctx.trigger.type === "schedule");
  const requestId = (ctx && ctx.request_id) || event.id || null;
  logInteraction("start", {
    request_id: requestId,
    scheduled: isScheduledCall,
    method: event.method || null,
  });

  const dryRun = asBool(query.dry_run, true);

  const update = parseJson(event.body);
  const hasWebhookUpdate = !!update;

  // Optional: full loop mode (self-contained)
  // POST /telegram-ai-reply?mode=loop&chat_id=123&prompt=Hola
  // If no webhook update is provided and chat_id is present, we default to loop mode.
  const modeRaw = String(query.mode || query.action || "").trim().toLowerCase();
  const wantsSingle = modeRaw === "reply" || modeRaw === "single" || modeRaw === "once";
  const wantsLoop = modeRaw === "loop" || asBool(query.loop, false);
  const loopEnabled = asBool(env.TELEGRAM_LOOP_ENABLED ?? process.env.TELEGRAM_LOOP_ENABLED, false);
  const loopToken = chooseSecret(env.TELEGRAM_LOOP_TOKEN, process.env.TELEGRAM_LOOP_TOKEN);

  if (wantsLoop) {
    if (!loopEnabled) {
      return json(403, { error: "loop mode disabled" });
    }
    if (loopToken && !isScheduledCall) {
      const provided = String(query.loop_token || query.loopToken || "");
      if (provided !== loopToken) {
        logInteraction("denied", {
          request_id: requestId,
          reason: "invalid_loop_token",
        });
        return json(403, { error: "invalid loop token" });
      }
    }
    const chatId = query.chat_id || query.chatId || env.TELEGRAM_CHAT_ID || process.env.TELEGRAM_CHAT_ID;
    const allChatsMode = !chatId;
    const prompt = String(query.prompt || query.prompt_text || query.text || "fastfn: responde y te contesto con IA");
    const sendPrompt = asBool(
      query.send_prompt,
      isScheduledCall
        ? asBool(env.TELEGRAM_LOOP_SEND_PROMPT_ON_SCHEDULE ?? process.env.TELEGRAM_LOOP_SEND_PROMPT_ON_SCHEDULE, false)
        : true
    );
    const waitSecs = Math.max(5, Math.min(120, Number(query.wait_secs || query.wait_s || 60)));
    const pollMs = Math.max(300, Math.min(5000, Number(query.poll_ms || 2000)));
    const maxReplies = Math.max(1, Math.min(50, Number(query.max_replies || query.max_msgs || 5)));
    const memCfg = memoryConfig(query);
    const forceClearWebhook = asBool(query.force_clear_webhook, false);
    const thinkCfg = thinkingConfig(env, query);

      if (dryRun) {
        logInteraction("dry_run_loop", {
          request_id: requestId,
          chat_id: chatId ? Number(chatId) : null,
          all_chats_mode: allChatsMode,
          send_prompt: sendPrompt,
        });
        return json(200, {
          ok: true,
          dry_run: true,
          mode: "loop",
          chat_id: chatId ? Number(chatId) : null,
          all_chats_mode: allChatsMode,
          send_prompt: sendPrompt,
          prompt,
          wait_secs: waitSecs,
          max_replies: maxReplies,
          note: allChatsMode
            ? "Set ?dry_run=false to poll Telegram updates and auto-reply to new text messages."
            : "Set ?dry_run=false to send prompt, wait for replies, and answer with OpenAI.",
        });
      }

    try {
      const loopLock = tryAcquireLoopLock(waitSecs + 60);
      if (!loopLock) {
        logInteraction("loop_skipped", {
          request_id: requestId,
          reason: "in_progress",
        });
        return json(isScheduledCall ? 200 : 409, {
          ok: isScheduledCall,
          skipped: true,
          reason: "in_progress",
          mode: "loop",
        });
      }

      try {
      if (!allChatsMode && sendPrompt && prompt) {
        await telegramSend(env, chatId, prompt, null);
      }

      const start = Date.now();
      const loopState = loadLoopState();
      let lastId = Number.isFinite(loopState.last_update_id) ? loopState.last_update_id : -1;
      try {
        if (forceClearWebhook) {
          await telegramDeleteWebhook(env);
        }
        if (lastId < 0) {
          const seed = await telegramGetUpdates(env);
          const res = Array.isArray(seed.result) ? seed.result : [];
          if (res.length > 0 && res[res.length - 1].update_id !== undefined) {
            lastId = res[res.length - 1].update_id;
            saveLoopState(lastId);
          }
        }
      } catch (err) {
        if (err && err.code === 409) {
          return json(isScheduledCall ? 200 : 409, {
            error: "getUpdates conflict (another polling client or webhook is active)",
            skipped: isScheduledCall,
            hint: "Stop other getUpdates clients or call with ?force_clear_webhook=true to clear webhook.",
          });
        }
        // ignore initial seed errors; we'll retry below
      }

      let repliesSent = 0;
      const handled = new Set();
      let transientErrors = 0;
      while ((Date.now() - start) / 1000 < waitSecs) {
        let updates;
        try {
          updates = await telegramGetUpdates(env, lastId >= 0 ? lastId + 1 : undefined);
        } catch (err) {
          if (err && err.code === 409) {
            return json(isScheduledCall ? 200 : 409, {
              error: "getUpdates conflict (another polling client or webhook is active)",
              skipped: isScheduledCall,
              hint: "Stop other getUpdates clients or call with ?force_clear_webhook=true to clear webhook.",
            });
          }
          transientErrors += 1;
          logInteraction("poll_error", {
            request_id: requestId,
            error: String(err && err.message ? err.message : err),
            transient: isTransientNetworkError(err),
            transient_errors: transientErrors,
          });
          await sleep(Math.min(5000, pollMs * 2));
          continue;
        }
        const res = Array.isArray(updates && updates.result) ? updates.result : [];
        for (const item of res) {
          if (item && typeof item.update_id === "number") {
            lastId = item.update_id;
          }
          const msg = (item && (item.message || item.edited_message)) || null;
          const chat = msg && msg.chat;
          const text = msg && (msg.text || msg.caption || "");
          const msgId = msg && (msg.message_id || null);
          if (msg && msg.from && msg.from.is_bot === true) {
            continue;
          }
          if (chat && text && (allChatsMode || String(chat.id) === String(chatId))) {
            const dedupeKey = String(item.update_id || msgId || "");
            if (dedupeKey && handled.has(dedupeKey)) {
              continue;
            }
            if (dedupeKey) handled.add(dedupeKey);
            const activeChatId = String(chat.id);
            const history = loadMemory(activeChatId, memCfg);
            if (thinkCfg.enabled && thinkCfg.text) {
              try {
                if (thinkCfg.mode === "text") {
                  await telegramSend(env, activeChatId, thinkCfg.text, msgId || null);
                } else {
                  try {
                    await telegramSendTypingAction(env, activeChatId);
                  } catch (typingErr) {
                    if (isTransientNetworkError(typingErr)) {
                      await sleep(250);
                      await telegramSendTypingAction(env, activeChatId);
                    } else {
                      throw typingErr;
                    }
                  }
                  if (thinkCfg.minMs > 0) {
                    await sleep(thinkCfg.minMs);
                  }
                }
              } catch (err) {
                logInteraction("thinking_error", {
                  request_id: requestId,
                  chat_id: Number(activeChatId),
                  error: String(err && err.message ? err.message : err),
                });
                if (thinkCfg.mode !== "text" && thinkCfg.fallbackText) {
                  try {
                    await telegramSend(env, activeChatId, thinkCfg.text, msgId || null);
                  } catch (_) {
                    // Best effort only; do not fail main reply path.
                  }
                }
              }
            }
            const toolContext = await resolveToolContext(text, env, query, requestId);
            let reply = "";
            let sent = null;
            try {
              const gen = await withTransientRetry(
                () => openaiGenerate(
                  env,
                  text,
                  Math.min(15000, ctx.timeout_ms || 8000),
                  history,
                  toolContext
                ),
                3,
                300
              );
              reply = gen.text.trim().slice(0, 3000);
              sent = await withTransientRetry(
                () => telegramSend(env, activeChatId, reply, msgId || null),
                3,
                250
              );
            } catch (err) {
              transientErrors += 1;
              logInteraction("reply_error", {
                request_id: requestId,
                chat_id: Number(activeChatId),
                update_id: item.update_id || null,
                error: String(err && err.message ? err.message : err),
                transient: isTransientNetworkError(err),
                transient_errors: transientErrors,
              });
              continue;
            }
            // Persist right after a successful send so transient errors later in the
            // loop do not reprocess the same Telegram update on the next scheduler run.
            saveLoopState(lastId);
            if (memCfg.enabled) {
              const now = Date.now();
              history.push({ role: "user", text: String(text), ts: now });
              history.push({ role: "assistant", text: String(reply), ts: now });
              saveMemory(activeChatId, memCfg, history);
            }
            repliesSent += 1;
            logInteraction("loop_replied", {
              request_id: requestId,
              chat_id: Number(activeChatId),
              update_id: item.update_id || null,
              message_id: msgId || null,
              replies_sent: repliesSent,
            });
            if (repliesSent >= maxReplies) {
              saveLoopState(lastId);
              return json(200, {
                ok: true,
                dry_run: false,
                mode: "loop",
                chat_id: allChatsMode ? null : Number(chatId),
                all_chats_mode: allChatsMode,
                replies_sent: repliesSent,
                reply_preview: reply,
                telegram: { message_id: sent.result && sent.result.message_id },
              });
            }
          }
        }
        await sleep(pollMs);
      }

      saveLoopState(lastId);
      logInteraction("loop_timeout", {
        request_id: requestId,
        chat_id: allChatsMode ? null : Number(chatId),
        replies_sent: repliesSent,
      });
      return json(isScheduledCall ? 200 : 504, {
        ok: isScheduledCall,
        skipped: isScheduledCall,
        error: "timeout waiting for reply",
        mode: "loop",
        chat_id: allChatsMode ? null : Number(chatId),
        all_chats_mode: allChatsMode,
        replies_sent: repliesSent,
        transient_errors: transientErrors,
      });
      } finally {
        releaseLoopLock(loopLock);
      }
      
    } catch (err) {
      logInteraction("loop_error", {
        request_id: requestId,
        error: String(err && err.message ? err.message : err),
      });
      return json(502, { error: String(err && err.message ? err.message : err), mode: "loop" });
    }
  }

  // Accept a real Telegram update via body (webhook style),
  // or a simple query-mode for manual E2E without setting a webhook:
  //   POST /telegram-ai-reply?chat_id=123&text=Hola
  let t = null;
  if (update) {
    t = extractTelegram(update);
  } else {
    const chatId = query.chat_id || query.chatId;
    const text = query.text;
    t = {
      chat_id: chatId != null ? Number(chatId) : null,
      text: text != null ? String(text) : "",
      message_id: null,
    };
  }
  if (!t.chat_id) {
    return json(200, { ok: true, note: "no chat_id provided; nothing to do" });
  }
  if (!t.text) {
    return json(200, { ok: true, chat_id: t.chat_id, note: "no text in update; nothing to do" });
  }

  if (dryRun) {
    logInteraction("dry_run_reply", {
      request_id: requestId,
      chat_id: Number(t.chat_id),
    });
    return json(200, {
      ok: true,
      dry_run: true,
      chat_id: t.chat_id,
      received_text: t.text,
      note: "Set ?dry_run=false and configure TELEGRAM_BOT_TOKEN + OPENAI_API_KEY to enable sending.",
    });
  }

  try {
    const memCfg = memoryConfig(query);
    const thinkCfg = thinkingConfig(env, query);
    const history = loadMemory(String(t.chat_id), memCfg);
    if (thinkCfg.enabled && thinkCfg.text) {
      try {
        if (thinkCfg.mode === "text") {
          await telegramSend(env, t.chat_id, thinkCfg.text, t.message_id);
        } else {
          try {
            await telegramSendTypingAction(env, t.chat_id);
          } catch (typingErr) {
            if (isTransientNetworkError(typingErr)) {
              await sleep(250);
              await telegramSendTypingAction(env, t.chat_id);
            } else {
              throw typingErr;
            }
          }
          if (thinkCfg.minMs > 0) {
            await sleep(thinkCfg.minMs);
          }
        }
      } catch (err) {
        logInteraction("thinking_error", {
          request_id: requestId,
          chat_id: Number(t.chat_id),
          error: String(err && err.message ? err.message : err),
        });
        if (thinkCfg.mode !== "text" && thinkCfg.fallbackText) {
          try {
            await telegramSend(env, t.chat_id, thinkCfg.text, t.message_id);
          } catch (_) {
            // Best effort only; do not fail main reply path.
          }
        }
      }
    }
    const toolContext = await resolveToolContext(t.text, env, query, requestId);
    const gen = await withTransientRetry(
      () => openaiGenerate(
        env,
        t.text,
        Math.min(15000, ctx.timeout_ms || 8000),
        history,
        toolContext
      ),
      3,
      300
    );
    const reply = gen.text.trim().slice(0, 3000);
    const sent = await withTransientRetry(
      () => telegramSend(env, t.chat_id, reply, t.message_id),
      3,
      250
    );
    if (memCfg.enabled) {
      const now = Date.now();
      history.push({ role: "user", text: String(t.text), ts: now });
      history.push({ role: "assistant", text: String(reply), ts: now });
      saveMemory(String(t.chat_id), memCfg, history);
    }
    logInteraction("reply_sent", {
      request_id: requestId,
      chat_id: Number(t.chat_id),
      message_id: sent.result && sent.result.message_id,
    });
    return json(200, {
      ok: true,
      dry_run: false,
      chat_id: t.chat_id,
      reply_preview: reply,
      telegram: { message_id: sent.result && sent.result.message_id },
    });
  } catch (err) {
    logInteraction("reply_error", {
      request_id: requestId,
      chat_id: Number(t.chat_id),
      error: String(err && err.message ? err.message : err),
    });
    return json(502, { error: String(err && err.message ? err.message : err) });
  }
};
