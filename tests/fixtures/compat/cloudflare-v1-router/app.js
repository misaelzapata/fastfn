/**
 * Handle incoming HTTP requests
 * @param {Request} request
 * @param {Env} env
 * @returns {Promise<Response>}
 */
module.exports = {
  async fetch(request, env) {
    try {
      // Handle CORS preflight requests
      if (request.method === "OPTIONS") {
        return handleCORS();
      }

      const url = new URL(request.url);
      const version = "v1";
      const basePath = `/api/${version}`;

      // Validate API version prefix
      if (!url.pathname.startsWith(basePath)) {
        return createErrorResponse("Invalid API version", 400);
      }

      // Basic router implementation with versioned endpoints
      switch (true) {
        case url.pathname === `${basePath}/status` && request.method === "GET":
          return handleHealthCheck(env);

        case url.pathname === `${basePath}/messages` &&
          request.method === "POST":
          return handleMessageCreate(request);

        default:
          return createErrorResponse("Not Found", 404);
      }
    } catch (error) {
      console.error("Error processing request:", error);
      return createErrorResponse("Internal Server Error", 500);
    }
  },
};

/**
 * Handle CORS preflight requests
 * @returns {Response}
 */
function handleCORS() {
  return new Response(null, {
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
      "Access-Control-Max-Age": "86400",
    },
  });
}

/**
 * Create a standardized error response
 * @param {string} message
 * @param {number} status
 * @returns {Response}
 */
function createErrorResponse(message, status) {
  return createJsonResponse(
    {
      success: false,
      error: {
        message,
        code: status,
      },
    },
    status,
  );
}

/**
 * Create a standardized JSON response
 * @param {object} data
 * @param {number} status
 * @returns {Response}
 */
function createJsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
  });
}

/**
 * Handle health check endpoint
 * @param {Env} env
 * @returns {Response}
 */
function handleHealthCheck(env) {
  const data = {
    success: true,
    data: {
      status: "healthy",
      environment: env.ENVIRONMENT,
      timestamp: new Date().toISOString(),
      version: "1.0.0",
    },
  };

  return createJsonResponse(data);
}

/**
 * Handle message creation endpoint
 * @param {Request} request
 * @returns {Promise<Response>}
 */
async function handleMessageCreate(request) {
  try {
    const contentType = request.headers.get("content-type");
    if (!contentType?.includes("application/json")) {
      return createErrorResponse("Content-Type must be application/json", 415);
    }

    const body = await request.json();

    // Validate required fields
    if (!body.message || typeof body.message !== "string") {
      return createErrorResponse(
        "Invalid message format. Message field is required and must be a string",
        400,
      );
    }

    const response = {
      success: true,
      data: {
        message: body.message,
        timestamp: new Date().toISOString(),
        id: crypto.randomUUID(),
      },
    };

    return createJsonResponse(response, 201);
  } catch (error) {
    return createErrorResponse("Invalid JSON payload", 400);
  }
}
