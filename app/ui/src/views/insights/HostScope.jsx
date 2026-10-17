/* The host scope (#101): one hostname - the seven-day class, kept only with
   PANEL_STATS_DOMAINS on (with it off the read says so, and so does the
   view). Its devices drill to the same hostname on that device. Its own
   timeline is floored at the class's cap, so the span older than that is
   the shade - "not kept" - rather than "before the data starts". */
const HostScope = {
  id: "host",
  order: ["device", "exit", "country", "category", "host"],
  drill: {
    device: (scope, value) => ({ client: value, host: scope.host }),
  },
  // its own bytes are what the shade marks as not kept - not "still real"
  shade: { label: "chart_shade_host" },
  shadeOverBefore: true,
  gateway: false,
};

export default HostScope;
