const http = require("http");
const fs = require("fs");
const path = require("path");

const host = "127.0.0.1";
const port = Number(process.env.PORT || 5500);
const root = __dirname;

const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
};

function send(res, status, body, contentType) {
  res.writeHead(status, {
    "Content-Type": contentType,
    "Cache-Control": "no-store",
  });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const urlPath = req.url === "/" ? "/index.html" : req.url;
  const safePath = path.normalize(urlPath).replace(/^([.][.][/\\])+/, "");
  const filePath = path.join(root, safePath);

  if (!filePath.startsWith(root)) {
    send(res, 403, "Forbidden", "text/plain; charset=utf-8");
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      send(res, 404, "Not Found", "text/plain; charset=utf-8");
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = mimeTypes[ext] || "application/octet-stream";
    send(res, 200, data, contentType);
  });
});

server.listen(port, host, () => {
  console.log(`Frontend running on http://${host}:${port}`);
});

server.on("error", (err) => {
  if (err && err.code === "EADDRINUSE") {
    console.error(`Port ${port} is already in use. Try: PORT=5501 npm run front`);
    process.exit(1);
  }

  throw err;
});
