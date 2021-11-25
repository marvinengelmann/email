from http.server import BaseHTTPRequestHandler


class handler(BaseHTTPRequestHandler):

    def do_GET(self):
        self.send_response(200)
        self.send_header(
            "Refresh",
            "0; url=mailto:hello@marvinengelmann.email"
        )
        self.end_headers()
        return
