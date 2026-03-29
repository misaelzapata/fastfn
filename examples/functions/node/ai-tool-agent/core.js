const {
  asBool,
  json,
  parseJson,
  toolConfig,
  memoryConfig,
  loadMemory,
  saveMemory,
  toolSchemas,
  executeToolCall,
  openaiChat,
  summarizeAssistantMessage
} = require("./_internal");

exports.handler = async (event) => {
  const env = event.env || {};
  const query = event.query || {};
  const bodyObj = parseJson(event.body) || {};
  const text = String(query.text ?? bodyObj.text ?? "").trim();
  const dryRun = asBool(query.dry_run ?? bodyObj.dry_run, true);

  const cfg = toolConfig(env, query, bodyObj);
  const memCfg = memoryConfig(env, query, bodyObj);
  const trace = {
    tool_allow: { fn: cfg.allowedFns, http_hosts: cfg.allowedHosts },
    steps: [],
    memory: { enabled: memCfg.enabled, agent_id: memCfg.agentId, path: memCfg.memPath },
  };

  if (!text) {
    return json(200, {
      ok: true,
      dry_run: true,
      note: "Provide text=... (the model will choose tools when dry_run=false).",
      examples: [
        "/ai-tool-agent?dry_run=true&text=what%20is%20my%20ip%20and%20weather%20in%20Buenos%20Aires%3F",
        "/ai-tool-agent?dry_run=false&text=what%20is%20my%20ip%20and%20weather%20in%20Buenos%20Aires%3F",
      ],
      tools: ["http_get", "fn_get"],
      tool_allow: trace.tool_allow,
    });
  }

  if (dryRun) {
    return json(200, {
      ok: true,
      dry_run: true,
      agent_id: memCfg.agentId,
      text,
      note: "Set dry_run=false to call OpenAI (tool-calling) and execute allowlisted tools.",
      tools: ["http_get", "fn_get"],
      tool_allow: trace.tool_allow,
    });
  }

  const history = loadMemory(memCfg);
  trace.memory.before = history.length;

  const nowUtc = new Date().toISOString();
  const system = [
    "You are an assistant running inside FastFN.",
    "You have access to tools and you MUST use them when needed to answer accurately.",
    "Use http_get for IP/weather and fn_get for internal summaries/debug helpers.",
    "Only call tools that are required to answer the user's question; keep tool calls minimal.",
    "After using tools, provide a concise final answer. Do not repeat raw JSON unless asked.",
    `Current UTC datetime: ${nowUtc}`,
  ].join("\\n");

  const messages = [{ role: "system", content: system }];
  for (const m of history) {
    messages.push({ role: m.role, content: m.text });
  }
  messages.push({ role: "user", content: text });

  const tools = toolSchemas(cfg);
  const timeoutMs = Math.max(
    1000,
    Math.min(Number((event.context && event.context.timeout_ms) || 12000) || 12000, 60000)
  );

  try {
    let finalText = "";
    for (let step = 0; step < cfg.maxSteps; step++) {
      const msg = await openaiChat(env, messages, tools, timeoutMs);
      trace.steps.push({ type: "openai", step: step + 1, message: summarizeAssistantMessage(msg) });

      const toolCalls = Array.isArray(msg.tool_calls) ? msg.tool_calls : [];
      if (toolCalls.length === 0) {
        finalText = typeof msg.content === "string" ? msg.content : "";
        break;
      }

      messages.push({
        role: "assistant",
        content: msg.content ?? null,
        tool_calls: toolCalls,
      });

      for (const call of toolCalls.slice(0, 6)) {
        const toolName = call && call.function && call.function.name ? String(call.function.name) : "";
        const argsRaw = call && call.function && typeof call.function.arguments === "string" ? call.function.arguments : "{}";
        const args = parseJson(argsRaw) || {};
        const result = await executeToolCall(toolName, args, cfg);
        trace.steps.push({
          type: "tool",
          step: step + 1,
          tool_call_id: call && call.id ? call.id : null,
          name: toolName,
          args,
          result,
        });
        messages.push({
          role: "tool",
          tool_call_id: call && call.id ? call.id : "",
          content: JSON.stringify(result),
        });
      }
    }

    if (!finalText) {
      return json(502, {
        error: "tool-calling did not converge",
        hint: "Increase max_steps or simplify the question.",
        trace,
      });
    }

    const now = Date.now();
    const updated = history.slice();
    updated.push({ role: "user", text, ts: now });
    updated.push({ role: "assistant", text: finalText, ts: now });
    saveMemory(memCfg, updated);
    trace.memory.after = updated.length;

    return json(200, {
      ok: true,
      dry_run: false,
      agent_id: memCfg.agentId,
      text,
      answer: finalText,
      trace,
    });
  } catch (err) {
    return json(502, {
      error: String(err && err.message ? err.message : err),
      trace,
    });
  }
};
