/* The client scope (#101): one device. Its own categories, hostnames, exit
   nodes and countries; a category or a hostname drills further while
   keeping the device, because the overview read takes the device together
   with one of them. Its device list is the device itself, and the coverage
   report is gateway-wide only - both come back `unavailable` and say so. */
const ClientScope = {
  id: "client",
  order: ["category", "host", "exit", "country", "device"],
  drill: {
    category: (scope, value) => ({ client: scope.client, app: value }),
    host: (scope, value) => ({ client: scope.client, host: value }),
  },
  shade: { label: "chart_shade" },
  shadeOverBefore: false,
  gateway: false,
};

export default ClientScope;
