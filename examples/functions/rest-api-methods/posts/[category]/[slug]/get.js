exports.handler = async (event, { category, slug }) => {
  // GET /posts/:category/:slug — both params arrive directly
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      category, slug,
      title: `${category}/${slug}`,
      url: `/posts/${category}/${slug}`,
    }),
  };
};
