import Box from "@mui/material/Box";

/* The time axis under a series: where it starts and ends, in the backend's
   own key strings (the same strings the marks carry), and the scale's top.
   Text, not SVG, so it never stretches with the chart. */
export default function Axis({ testid, start, end, top }) {
  if (!start) return null;
  return (
    <Box data-testid={testid} sx={{
      display: "flex", justifyContent: "space-between", gap: 1,
      fontSize: "0.75rem", color: "text.secondary", mt: 0.25,
      fontFamily: "ui-monospace, monospace", overflowWrap: "anywhere",
    }}>
      <span data-testid={`${testid}-start`}>{start}</span>
      {top ? <span data-testid={`${testid}-top`}>{top}</span> : null}
      <span data-testid={`${testid}-end`}>{end}</span>
    </Box>
  );
}
