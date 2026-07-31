import Container from "@mui/material/Container";
import Typography from "@mui/material/Typography";

/**
 * The scaffold shell (#78). Deliberately minimal: this item introduces the
 * toolchain and proves the shipped image can build it; the stats-first
 * rewrite that fills it in is a separate item.
 *
 * The classic UI at /ui/ is untouched and still the one users see - this
 * tree is served additively at /ui/next/ until that rewrite lands, so a
 * working panel is never replaced by a scaffold.
 *
 * Every interactive element carries a stable data-testid, the repo rule the
 * Playwright gate will ride on.
 */
export default function App() {
  return (
    <Container maxWidth="sm" data-testid="app-shell">
      <Typography variant="h5" component="h1" data-testid="app-title">
        Gateway Panel
      </Typography>
      <Typography variant="body2" data-testid="app-shell-note">
        New panel UI - toolchain scaffold. The current panel remains at /ui/.
      </Typography>
    </Container>
  );
}
