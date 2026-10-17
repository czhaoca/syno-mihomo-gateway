import Box from "@mui/material/Box";
import Typography from "@mui/material/Typography";

/* The frame every chart sits in (#100), and the one place a chart says how
   far its picture can be trusted. Four states, each with its own testid:

     fresh        the newest answer, drawn
     stale        an answer is drawn, but the collector has not polled
                  since SINCE (or the last refresh failed) - kept, labelled
     unavailable  no answer could be read (REASON: "unreachable" or
                  "unavailable") - nothing is drawn, because an empty chart
                  and an unreadable one are pixel-identical and mean
                  opposite things
     empty        an answer with nothing in it: no traffic in the window
                  (EMPTY_TEXT says what that means for a scope)

   Before the first answer there is no state at all - no "no traffic" text a
   reader could take for a measurement. */
export default function ChartFrame({ id, state = null, since = "", reason = "",
                                      t, children, minHeight = 60,
                                      emptyText = "" }) {
  const drawn = state === "fresh" || state === "stale";
  return (
    <Box data-testid={id} data-state={state || "none"}
         sx={{ position: "relative", minHeight }}>
      {state === "fresh" ? <span data-testid={`${id}-fresh`} hidden /> : null}
      {state === "stale" ? (
        <Typography variant="body2" color="warning.main"
                    data-testid={`${id}-stale`} sx={{ mb: 0.5 }}>
          {`${t("chart_stale_since")} ${since}`}
        </Typography>
      ) : null}
      {state === "unavailable" ? (
        <Typography variant="body2" color="warning.main"
                    data-testid={`${id}-unavailable`}>
          {reason === "unreachable" ? t("chart_unreachable")
            : t("chart_unavailable")}
        </Typography>
      ) : null}
      {state === "empty" ? (
        <Typography variant="body2" color="text.secondary"
                    data-testid={`${id}-empty`}>
          {emptyText || t("chart_empty")}
        </Typography>
      ) : null}
      {drawn ? children : null}
    </Box>
  );
}
