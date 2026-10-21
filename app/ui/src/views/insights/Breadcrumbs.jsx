import Box from "@mui/material/Box";

/* Where a drill has led (#101): Overview, then the client, then its
   category or hostname. Every crumb but the last is a native link back to
   that level (back/forward work too - the route is the hash); the last is
   the page itself. CRUMBS: [{key, label, href}] in order. */
export default function Breadcrumbs({ crumbs, t }) {
  return (
    <Box component="nav" aria-label={t("crumbs_label")} data-testid="stats-crumbs"
         sx={{ display: "flex", flexWrap: "wrap", alignItems: "center",
               columnGap: 0.75, fontSize: "0.9rem", minWidth: 0 }}>
      {crumbs.map((crumb, i) => {
        const last = i === crumbs.length - 1;
        return (
          <Box key={crumb.key} component="span"
               sx={{ display: "inline-flex", alignItems: "center", gap: 0.75,
                     minWidth: 0 }}>
            {last ? (
              <Box component="span" aria-current="page"
                   data-testid={`stats-crumb-${crumb.key}`}
                   sx={{ fontWeight: 600, overflowWrap: "anywhere" }}>
                {crumb.label}
              </Box>
            ) : (
              <Box component="a" href={crumb.href}
                   data-testid={`stats-crumb-${crumb.key}`}
                   sx={{ color: "primary.main", minHeight: 44,
                         display: "inline-flex", alignItems: "center",
                         overflowWrap: "anywhere" }}>
                {crumb.label}
              </Box>
            )}
            {last ? null : <Box component="span" aria-hidden="true"
                                sx={{ color: "text.secondary" }}>/</Box>}
          </Box>
        );
      })}
    </Box>
  );
}
