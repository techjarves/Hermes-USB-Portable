#!/usr/bin/env python3
import os
import sys
import json
import time
import zipfile
import threading
import urllib.request
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# Add the scripts directory to path to import hardware_detector
scripts_dir = Path(__file__).parent.resolve()
sys.path.append(str(scripts_dir))

import hardware_detector

# Global state to track configuration and download progress
state = {
    "step": "welcome",
    "system_specs": None,
    "recommended_models": [],
    "active_model_name": "",
    "download_status": {
        "active": False,
        "type": "",  # "server" or "model"
        "filename": "",
        "downloaded_bytes": 0,
        "total_bytes": 0,
        "speed_mb": 0.0,
        "percent": 0.0,
        "error": None,
        "complete": False
    }
}

LLAMA_CPP_VERSION = "b4600"

def get_server_download_url(system):
    """Determine the correct llama-server download URL based on detected hardware."""
    platform_name = system.get("platform", "").lower()
    backend = system.get("backend", "").lower()
    
    base_url = f"https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA_CPP_VERSION}/"
    
    if "windows" in platform_name:
        if backend == "cuda":
            return base_url + f"llama-{LLAMA_CPP_VERSION}-bin-win-cuda-cu12.4-x64.zip"
        elif backend == "cpu_x86":
            return base_url + f"llama-{LLAMA_CPP_VERSION}-bin-win-avx2-x64.zip"
        else:
            # Default to Vulkan for portable GPU acceleration
            return base_url + f"llama-{LLAMA_CPP_VERSION}-bin-win-vulkan-x64.zip"
    elif "darwin" in platform_name or "mac" in platform_name:
        if "arm" in system.get("cpu_name", "").lower() or backend == "metal":
            return base_url + f"llama-{LLAMA_CPP_VERSION}-bin-macos-arm64.zip"
        else:
            return base_url + f"llama-{LLAMA_CPP_VERSION}-bin-macos-x64.zip"
    else:  # Linux / fallback
        # Linux standard zip includes compiled binaries for cpu/vulkan
        return base_url + f"llama-{LLAMA_CPP_VERSION}-bin-ubuntu-x64.zip"

def download_file_in_thread(url, dest_path, download_type):
    """Downloads a file and updates the global download status."""
    global state
    state["download_status"] = {
        "active": True,
        "type": download_type,
        "filename": os.path.basename(dest_path),
        "downloaded_bytes": 0,
        "total_bytes": 0,
        "speed_mb": 0.0,
        "percent": 0.0,
        "error": None,
        "complete": False
    }
    
    try:
        headers = {'User-Agent': 'Mozilla/5.0'}
        req = urllib.request.Request(url, headers=headers)
        
        with urllib.request.urlopen(req, timeout=15) as response:
            total_bytes = int(response.headers.get('content-length', 0))
            state["download_status"]["total_bytes"] = total_bytes
            
            os.makedirs(os.path.dirname(dest_path), exist_ok=True)
            temp_path = dest_path + ".downloading"
            
            start_time = time.time()
            downloaded = 0
            chunk_size = 1024 * 1024 # 1MB
            
            with open(temp_path, "wb") as f_out:
                while True:
                    chunk = response.read(chunk_size)
                    if not chunk:
                        break
                    f_out.write(chunk)
                    downloaded += len(chunk)
                    
                    elapsed = time.time() - start_time
                    speed_mb = (downloaded / (1024 * 1024)) / elapsed if elapsed > 0 else 0
                    percent = (downloaded / total_bytes * 100) if total_bytes > 0 else 0
                    
                    state["download_status"].update({
                        "downloaded_bytes": downloaded,
                        "speed_mb": round(speed_mb, 2),
                        "percent": round(percent, 1)
                    })
            
            if os.path.exists(dest_path):
                os.remove(dest_path)
            os.rename(temp_path, dest_path)
            
            state["download_status"].update({
                "active": False,
                "complete": True,
                "percent": 100.0
            })
    except Exception as e:
        state["download_status"].update({
            "active": False,
            "error": str(e)
        })

def download_model_callback(filename, downloaded, total, speed, percent):
    """Callback function used by hardware_detector.download_hf_model."""
    global state
    state["download_status"].update({
        "active": True,
        "type": "model",
        "filename": filename,
        "downloaded_bytes": downloaded,
        "total_bytes": total,
        "speed_mb": round(speed, 2),
        "percent": round(percent, 1)
    })

def download_model_in_thread(repo_id, pattern, target_dir):
    """Background task to download GGUF model from Hugging Face."""
    global state
    try:
        hardware_detector.download_hf_model(
            repo_id_or_url=repo_id,
            pattern=pattern,
            target_dir=target_dir,
            progress_callback=download_model_callback
        )
        state["download_status"].update({
            "active": False,
            "complete": True,
            "percent": 100.0
        })
    except Exception as e:
        state["download_status"].update({
            "active": False,
            "error": str(e)
        })

def configure_hermes(model_name):
    """Updates config.yaml and .env to set local llama-server as the provider."""
    portable_root = scripts_dir.parent.resolve()
    data_dir = portable_root / "data"
    config_path = data_dir / "config.yaml"
    env_path = data_dir / ".env"
    
    # 1. Update config.yaml using raw replacement to preserve yaml comments/structure
    if config_path.exists():
        try:
            content = config_path.read_text(encoding="utf-8")
            
            lines = content.splitlines()
            model_found = False
            new_lines = []
            
            for line in lines:
                if line.strip().startswith("model:") and not model_found:
                    new_lines.append("model:")
                    new_lines.append(f'  default: "custom/{model_name}"')
                    new_lines.append('  provider: "custom"')
                    new_lines.append('  base_url: "http://127.0.0.1:39600/v1"')
                    new_lines.append('  context_length: 32768')
                    model_found = True
                elif model_found and (line.startswith("  default:") or line.startswith("  provider:") or line.startswith("  base_url:") or line.startswith("  context_length:")):
                    # Skip existing model settings
                    continue
                else:
                    new_lines.append(line)
            
            config_path.write_text("\n".join(new_lines), encoding="utf-8")
        except Exception as e:
            print(f"Error updating config.yaml: {e}", file=sys.stderr)
            return False
            
    # 2. Update .env file to ensure setup registers as configured
    try:
        env_content = ""
        if env_path.exists():
            env_content = env_path.read_text(encoding="utf-8")
            
        lines = env_content.splitlines()
        has_local_key = False
        new_lines = []
        for line in lines:
            if line.startswith("CUSTOM_API_KEY="):
                new_lines.append("CUSTOM_API_KEY=local-llama-server")
                has_local_key = True
            else:
                new_lines.append(line)
        if not has_local_key:
            new_lines.append("CUSTOM_API_KEY=local-llama-server")
            
        env_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    except Exception as e:
        print(f"Error updating .env: {e}", file=sys.stderr)
        return False
        
    return True

class SetupRequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress server logging to keep CLI clean
        pass
        
    def do_GET(self):
        global state
        parsed_path = urllib.parse.urlparse(self.path)
        path = parsed_path.path
        
        # Serve frontend web assets
        if path == "/" or path == "/index.html":
            self.serve_file(scripts_dir / "web" / "index.html", "text/html")
        elif path == "/style.css":
            self.serve_file(scripts_dir / "web" / "style.css", "text/css")
        elif path == "/app.js":
            self.serve_file(scripts_dir / "web" / "app.js", "application/javascript")
            
        # APIs
        elif path == "/api/detect":
            # Detect system specs
            if not state["system_specs"]:
                state["system_specs"] = hardware_detector.detect_system()
                state["recommended_models"] = hardware_detector.rank_models(
                    state["system_specs"], 
                    hardware_detector.EMBEDDED_MODELS
                )
            
            response_data = {
                "system": state["system_specs"],
                "recommendations": state["recommended_models"],
                "llama_version": LLAMA_CPP_VERSION
            }
            self.send_json(response_data)
            
        elif path == "/api/status":
            self.send_json(state)
            
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        global state
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else ""
        
        parsed_path = urllib.parse.urlparse(self.path)
        path = parsed_path.path
        
        if path == "/api/download-server":
            if state["download_status"]["active"]:
                self.send_json({"error": "A download is already active"}, 400)
                return
                
            if not state["system_specs"]:
                state["system_specs"] = hardware_detector.detect_system()
                
            url = get_server_download_url(state["system_specs"])
            portable_root = scripts_dir.parent.resolve()
            dest_path = portable_root / ".cache" / "runtimes" / "llama-server.zip"
            
            # Reset download status for server download
            state["download_status"] = {
                "active": True,
                "type": "server",
                "filename": os.path.basename(dest_path),
                "downloaded_bytes": 0,
                "total_bytes": 0,
                "speed_mb": 0.0,
                "percent": 0.0,
                "error": None,
                "complete": False
            }
            
            # Start background thread to download llama-server zip
            thread = threading.Thread(
                target=download_file_in_thread, 
                args=(url, str(dest_path), "server")
            )
            thread.daemon = True
            thread.start()
            
            self.send_json({"status": "started", "url": url})
            
        elif path == "/api/extract-server":
            # Extract downloaded zip
            portable_root = scripts_dir.parent.resolve()
            zip_path = portable_root / ".cache" / "runtimes" / "llama-server.zip"
            dest_dir = portable_root / ".cache" / "runtimes" / "llama-server"
            
            if not zip_path.exists():
                self.send_json({"error": "Server archive not found"}, 400)
                return
                
            try:
                # Clear destination directory to prevent stale backend DLLs (like CUDA/Vulkan)
                if dest_dir.exists():
                    try:
                        import shutil
                        shutil.rmtree(dest_dir, ignore_errors=True)
                    except Exception:
                        pass
                os.makedirs(dest_dir, exist_ok=True)
                with zipfile.ZipFile(zip_path, 'r') as zip_ref:
                    zip_ref.extractall(dest_dir)
                
                # Ensure binary executable on non-Windows
                if os.name != 'nt':
                    for binary in ["llama-server", "llama-cli"]:
                        bin_path = dest_dir / binary
                        if bin_path.exists():
                            bin_path.chmod(0o755)
                            
                # Cleanup zip
                if zip_path.exists():
                    os.remove(zip_path)
                    
                self.send_json({"status": "success"})
            except Exception as e:
                self.send_json({"error": f"Extraction failed: {e}"}, 500)
                
        elif path == "/api/download-model":
            if state["download_status"]["active"]:
                self.send_json({"error": "A download is already active"}, 400)
                return
                
            try:
                params = json.loads(body)
                repo_id = params.get("repo_id")
                pattern = params.get("pattern")
                if not pattern:
                    pattern = None
                
                if not repo_id:
                    self.send_json({"error": "Missing repo_id"}, 400)
                    return
                
                # Reset download status for model download
                state["download_status"] = {
                    "active": True,
                    "type": "model",
                    "filename": "Connecting to Hugging Face...",
                    "downloaded_bytes": 0,
                    "total_bytes": 0,
                    "speed_mb": 0.0,
                    "percent": 0.0,
                    "error": None,
                    "complete": False
                }
                
                portable_root = scripts_dir.parent.resolve()
                models_dir = portable_root / "data" / "models"
                
                # Start background thread for model download
                thread = threading.Thread(
                    target=download_model_in_thread,
                    args=(repo_id, pattern, str(models_dir))
                )
                thread.daemon = True
                thread.start()
                
                self.send_json({"status": "started"})
            except Exception as e:
                self.send_json({"error": str(e)}, 500)
                
        elif path == "/api/configure":
            try:
                params = json.loads(body)
                model_file = params.get("model_file")
                if not model_file:
                    self.send_json({"error": "Missing model_file"}, 400)
                    return
                    
                success = configure_hermes(model_file)
                if success:
                    self.send_json({"status": "success"})
                else:
                    self.send_json({"error": "Failed to update configuration files"}, 500)
            except Exception as e:
                self.send_json({"error": str(e)}, 500)
                
        elif path == "/api/shutdown":
            self.send_json({"status": "shutting down"})
            def shutdown_delayed():
                time.sleep(1)
                os._exit(0)
            threading.Thread(target=shutdown_delayed).start()
            
        else:
            self.send_response(404)
            self.end_headers()

    def serve_file(self, file_path, content_type):
        if not file_path.exists():
            self.send_response(404)
            self.end_headers()
            return
            
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(file_path.read_bytes())

    def send_json(self, data, status_code=200):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

def find_free_port(start_port=5000, max_port=5100):
    import socket
    for port in range(start_port, max_port):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(('127.0.0.1', port))
                return port
            except OSError:
                continue
    return start_port

def start_server():
    port = find_free_port()
    server_address = ('127.0.0.1', port)
    httpd = HTTPServer(server_address, SetupRequestHandler)
    
    url = f"http://127.0.0.1:{port}/"
    print("\n" + "="*60)
    print("🛸 HERMES PORTABLE LOCAL LLM CONFIGURATION SERVER")
    print("="*60)
    print(f"Opening browser configuration helper at:")
    print(f"👉 {url}")
    print("="*60)
    
    import webbrowser
    def open_browser():
        time.sleep(0.5)
        webbrowser.open_new_tab(url)
    threading.Thread(target=open_browser).start()
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down configuration server...")
        sys.exit(0)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--test-endpoints":
        print("Testing configuration writer...")
        test_success = configure_hermes("qwen2.5-coder-7b-instruct-q4_k_m.gguf")
        print(f"Configuration test: {'SUCCESS' if test_success else 'FAILED'}")
        sys.exit(0 if test_success else 1)
        
    start_server()
