import Box from "@mui/material/Box";

/* A DOM overlay for the mark under the pointer or the keyboard (#100
   DEC-A): unlike an SVG <title> it shows on focus and touch, and can say
   WHY a bucket has no value. Positioned in percent of the chart's width, so
   it follows the chart at any size; clamped so it never pushes the page
   wider than the viewport. */
export default function Tooltip({ testid, at, lines }) {
  if (at === null || at === undefined || !lines || !lines.length) return null;
  const left = Math.min(Math.max(at, 0), 100);
  return (
    <Box
      data-testid={testid}
      role="status"
      sx={{
        position: "absolute", top: 4, left: `${left}%`,
        transform: left > 60 ? "translateX(-100%)" : "none",
        maxWidth: "70%", pointerEvents: "none", zIndex: 2,
        px: 1, py: 0.5, borderRadius: 1, fontSize: "0.8rem",
        bgcolor: "background.paper", color: "text.primary",
        border: 1, borderColor: "divider", boxShadow: 2,
      }}
    >
      {lines.map((line) => <Box key={line}>{line}</Box>)}
    </Box>
  );
}
