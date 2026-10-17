/* The overview scope (#101): the whole gateway. Every top list the overview
   read answers, and the gateway-wide notes - the attribution share, the
   coverage report and what the panel cannot see - which are measured for
   the whole gateway only. A device drills to its client scope, a category
   to its category scope, a hostname to its host scope. */
const Overview = {
  id: "overview",
  order: ["device", "category", "exit", "country", "host"],
  drill: {
    device: (_scope, value) => ({ client: value }),
    category: (_scope, value) => ({ app: value }),
    host: (_scope, value) => ({ host: value }),
  },
  // the timeline is device bytes, kept long-term: past the hostname class's
  // cap only the detail is gone, so the shade sits beside the "before"
  shade: { label: "chart_shade" },
  shadeOverBefore: false,
  gateway: true,
};

export default Overview;
