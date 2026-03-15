import http.server
import socketserver
import json
import crypt
import sys

PORT = 8100
CREDENTIALS_FILE = "/app/visionstack_credentials.txt"
SHADOW_FILE = "/host/shadow" # Mounted securely as Read-Only

class AuthHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()

    def do_GET(self):
        # Serve index.html by default
        if self.path == '/':
            self.path = '/index.html'
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path == '/api/unlock':
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self.send_error(400, "Bad Request")
                return

            post_data = self.rfile.read(content_length)
            
            try:
                data = json.loads(post_data.decode('utf-8'))
                username = data.get('username')
                password = data.get('password')

                if not username or not password:
                    self.send_error(400, "Missing credentials")
                    return

                if self.authenticate_linux_user(username, password):
                    self.send_response(200)
                    self.send_header('Content-type', 'text/plain')
                    self.end_headers()
                    
                    try:
                        with open(CREDENTIALS_FILE, 'r') as f:
                            creds = f.read()
                        self.wfile.write(creds.encode('utf-8'))
                    except FileNotFoundError:
                        self.wfile.write(b"Error: visionstack_credentials.txt not found.")
                else:
                    self.send_error(401, "Unauthorized")
            
            except json.JSONDecodeError:
                self.send_error(400, "Invalid JSON")
        else:
            self.send_error(404, "Not Found")

    def authenticate_linux_user(self, username, password):
        """ Checks the submitted password against the host's /etc/shadow file """
        try:
            with open(SHADOW_FILE, 'r') as f:
                for line in f:
                    parts = line.split(':')
                    if parts[0] == username:
                        shadow_hash = parts[1]
                        
                        # Use crypt to hash the input password with the salt from the shadow file
                        if crypt.crypt(password, shadow_hash) == shadow_hash:
                            return True
                        return False
            return False
        except PermissionError:
            print("Error: The python container does not have permission to read the shadow file.", file=sys.stderr)
            return False
        except FileNotFoundError:
            print("Error: /host/shadow was not mounted.", file=sys.stderr)
            return False

with socketserver.TCPServer(("", PORT), AuthHandler) as httpd:
    print(f"Starting VisionStack Vault Server on port {PORT}")
    httpd.serve_forever()
