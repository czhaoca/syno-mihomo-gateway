import Button from "@mui/material/Button";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";

import TopBars from "../../charts/TopBars.jsx";
import { LIMIT_MAX, fmtBytes } from "../../stats.js";

/* One dimension's top list (#101): BODY is the overview's breakdown answer
   for DIM, COUNT how many of its values this list shows. Nothing past the
   shown rows is dropped silently - the remainder (how many values, how many
   bytes, from the whole-window `total`) is said, and "show more" asks for
   more while the list has more than it shows (DEC-B). At the server's clamp
   the list says how many it could not list. A long-term list also says what
   it has no record of (`unrecorded`) and where its data starts. */
export default function TopList({ t, dim, title, body, count, labelOf, hrefOf,
                                  onMore, busy }) {
  const shown = body.rows.slice(0, count);
  const total = (body.total ? body.total.up + body.total.down : 0);
  const listed = shown.reduce((sum, r) => sum + r.up + r.down, 0);
  const rest = Math.max(0, (body.total_rows || 0) - shown.length);
  const capped = count >= LIMIT_MAX && rest > 0;
  const unrecorded = body.unrecorded
    ? body.unrecorded.up + body.unrecorded.down : 0;
  const span = body.window || {};
  const rows = shown.map((row) => ({
    key: row.value, label: labelOf(row), up: row.up, down: row.down,
    href: hrefOf ? hrefOf(row.value) : null,
  }));
  return (
    <Stack spacing={0.5} data-testid={`stats-list-${dim}`} sx={{ minWidth: 0 }}>
      <Typography variant="subtitle2">{title}</Typography>
      {rows.length ? (
        <TopBars testid={`stats-top-${dim}`} rows={rows} />
      ) : (
        <Typography variant="body2" color="text.secondary"
                    data-testid={`stats-top-${dim}-empty`}>
          {t("list_empty")}
        </Typography>
      )}
      {rest > 0 ? (
        <Typography variant="body2" color="text.secondary"
                    data-testid={`stats-top-${dim}-rest`} data-rest={rest}>
          {`${capped ? `${t("list_capped")} ${LIMIT_MAX} / ${body.total_rows}. ` : ""}`
           + `${t("list_rest")}: ${rest} (${fmtBytes(Math.max(0, total - listed))})`}
        </Typography>
      ) : null}
      {rest > 0 && count < LIMIT_MAX ? (
        <Button data-testid={`stats-more-${dim}`} disabled={busy}
                onClick={() => onMore(dim)} sx={{ alignSelf: "flex-start" }}>
          {t("show_more")}
        </Button>
      ) : null}
      {unrecorded > 0 ? (
        <Typography variant="body2" color="warning.main"
                    data-testid={`stats-top-${dim}-unrecorded`}>
          {`${t("list_unrecorded")}: ${fmtBytes(unrecorded)}`}
        </Typography>
      ) : null}
      {span.truncated && span.oldest_bucket ? (
        <Typography variant="body2" color="text.secondary"
                    data-testid={`stats-top-${dim}-window`}>
          {`${t("list_starts")} ${span.oldest_bucket}`}
        </Typography>
      ) : null}
    </Stack>
  );
}
