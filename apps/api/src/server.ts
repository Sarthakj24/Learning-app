import "./middleware/types"; // load Express type augmentation
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

// Centralised error handler
app.use((err: any, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error(err);
  res.status(500).json({ error: "Internal server error" });
});

app.listen(env.PORT, () => {
  console.log(`WH Now Learn API listening on :${env.PORT}`);
});
