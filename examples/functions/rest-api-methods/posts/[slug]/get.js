exports.handler = async (event, { slug }) => {
  // GET /posts/:slug — slug arrives directly from [slug] filename
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ slug, title: `Post: ${slug}`, content: "Lorem ipsum..." }),
  };
};
