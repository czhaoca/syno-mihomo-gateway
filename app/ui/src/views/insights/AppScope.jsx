/* The category scope (#101 DEC-F) - routed as `app`, named "Category" on
   screen: one value of the category dimension (a coarse id, `unknown`, or
   the empty value counted without a dictionary). The overview read has no
   app-level-id scope, and no stored table joins a category to its exit
   nodes, countries or hostnames: those lists come back `unavailable`, and
   the view says why instead of showing them empty. Its devices drill to the
   same category on that device.

   The category dimension is kept long-term, so there is no hostname-class
   shade here: nothing in this scope ages out at seven days. */
const AppScope = {
  id: "app",
  order: ["device", "exit", "country", "host", "category"],
  drill: {
    device: (scope, value) => ({ client: value, app: scope.app }),
  },
  shade: null,
  shadeOverBefore: false,
  gateway: false,
};

export default AppScope;
