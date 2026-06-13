import "./middleware/types"; // load Express type augmentation
import path from "path";
import fs from "fs";
import express from "express";
import cors from "cors";
import { env } from "./env";
import { authRouter } from "./routes/auth.routes";
import { apiRouter } from "./routes/api.routes";

const app = express();
app.use(cors({ origin: env.WEB_ORIGIN === "*" ? true : env.WEB_ORIGIN.split(",") }));
app.use(express.json());

app.get("/health", (_req, res) => res.json({ ok: true, service: "whnow-learn-api" }));
app.use("/auth", authRouter);
app.use("/api", apiRouter);

// Serve the built web app from the same origin (single-service deploy). The
// API build copies the Vite output into ./public next to the compiled server.
// When it's absent (local API-only dev) fall back to a friendly JSON root.
const webDir = path.join(__dirname, "public");
if (fs.existsSync(path.join(webDir, "index.html"))) {
  app.use(express.static(webDir));
  // SPA fallback: serve index.html for any non-API GET so client routes resolve.
  app.get("*", (req, res, next) => {
    if (
      req.path.startsWith("/api") ||
      req.path.startsWith("/auth") ||
      req.path === "/health"
    ) {
      return next();
    }
    res.sendFile(path.join(webDir, "index.html"));
  });
} else {
  app.get("/", (_req, res) =>
    res.json({
      service: "whnow-learn-api",
      message: "API only; the web build is not bundled in this environment.",
      endpoints: ["/health", "/auth/login", "/api/*"],
    }),
  );
}

// Centralised error handler
app.use((err: any, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error(err);
  res.status(500).json({ error: "Internal server error" });
});

app.listen(env.PORT, () => {
  console.log(`WH Now Learn API listening on :${env.PORT}`);
});
