#!/usr/bin/env python3
"""
Hardware Detector & Model Fitting Utility
A standalone, self-contained Python script to:
1. Detect system hardware: CPU, RAM, and GPUs (Windows, macOS, Linux/WSL).
2. Estimate LLM memory requirements and token-per-second generation speeds.
3. Recommend and rank LLM models suitable for the detected hardware.

No external dependencies (standard library only).
"""

import os
import platform
import re
import shutil
import subprocess
import json
import sys

# ── HARDWARE DETECTION CONSTANTS & SETUP ──────────────────────────────────────

NVIDIA_PATH_CANDIDATES = (
    "/usr/bin/nvidia-smi",
    "/usr/local/bin/nvidia-smi",
    "/usr/local/cuda/bin/nvidia-smi",
    "/usr/lib/wsl/lib/nvidia-smi",
)

# ── MODEL FITTING CONSTANTS & DICTIONARIES ────────────────────────────────────

QUANT_HIERARCHY = ["Q8_0", "Q6_K", "Q5_K_M", "Q4_K_M", "Q3_K_M", "Q2_K"]

QUANT_BPP = {
    "F32": 4.0, "F16": 2.0, "BF16": 2.0, "FP8": 1.0,
    "FP4": 0.50, "NVFP4": 0.50, "MXFP4": 0.50, "NF4": 0.50,
    "INT4": 0.50, "INT8": 1.0, "W4A16": 0.50, "W8A8": 1.0, "W8A16": 1.0,
    "Q8_0": 1.05, "Q6_K": 0.80, "Q5_K_M": 0.68,
    "Q4_K_M": 0.58, "Q4_0": 0.58, "Q3_K_M": 0.48, "Q2_K": 0.37,
    "AWQ-4bit": 0.50, "AWQ-8bit": 1.0,
    "GPTQ-Int4": 0.50, "GPTQ-Int8": 1.0,
    "mlx-4bit": 0.55, "mlx-8bit": 1.0, "mlx-6bit": 0.75,
    "FP4-MoE-Mixed": 0.55,
    "FP8-Mixed": 1.0,
}

QUANT_SPEED_MULT = {
    "F16": 0.6, "BF16": 0.6, "FP8": 0.85,
    "FP4": 1.15, "NVFP4": 1.15, "MXFP4": 1.15, "NF4": 1.10,
    "INT4": 1.15, "INT8": 0.85, "W4A16": 1.15, "W8A8": 0.85, "W8A16": 0.85,
    "Q8_0": 0.8, "Q6_K": 0.95, "Q5_K_M": 1.0,
    "Q4_K_M": 1.15, "Q4_0": 1.15, "Q3_K_M": 1.25, "Q2_K": 1.35,
    "AWQ-4bit": 1.2, "AWQ-8bit": 0.85,
    "GPTQ-Int4": 1.2, "GPTQ-Int8": 0.85,
    "mlx-4bit": 1.15, "mlx-8bit": 0.85, "mlx-6bit": 1.0,
    "FP4-MoE-Mixed": 1.10,
    "FP8-Mixed": 0.85,
}

QUANT_QUALITY_PENALTY = {
    "F16": 0.0, "BF16": 0.0, "FP8": 0.0,
    "FP4": -3.0, "NVFP4": -3.0, "MXFP4": -3.0, "NF4": -4.0,
    "INT4": -4.0, "INT8": 0.0, "W4A16": -4.0, "W8A8": 0.0, "W8A16": 0.0,
    "Q8_0": 0.0, "Q6_K": -1.0, "Q5_K_M": -2.0,
    "Q4_K_M": -5.0, "Q4_0": -5.0, "Q3_K_M": -8.0, "Q2_K": -12.0,
    "AWQ": -1.0, "AWQ-4bit": -4.0, "AWQ-8bit": -1.0,
    "GPTQ": -1.0, "GPTQ-Int4": -4.0, "GPTQ-Int8": -1.0,
    "mlx-4bit": -4.0, "mlx-8bit": -0.5, "mlx-6bit": -1.5,
    "FP4-MoE-Mixed": -0.5,
    "FP8-Mixed": 0.0,
}

QUANT_BYTES_PER_PARAM = {
    "F16": 2.0, "BF16": 2.0, "FP8": 1.0,
    "FP4": 0.5, "NVFP4": 0.5, "MXFP4": 0.5, "NF4": 0.5,
    "INT4": 0.5, "INT8": 1.0, "W4A16": 0.5, "W8A8": 1.0, "W8A16": 1.0,
    "Q8_0": 1.0, "Q6_K": 0.75, "Q5_K_M": 0.625,
    "Q4_K_M": 0.5, "Q4_0": 0.5, "Q3_K_M": 0.375, "Q2_K": 0.25,
    "AWQ-4bit": 0.5, "AWQ-8bit": 1.0,
    "GPTQ-Int4": 0.5, "GPTQ-Int8": 1.0,
    "mlx-4bit": 0.5, "mlx-8bit": 1.0, "mlx-6bit": 0.75,
    "FP4-MoE-Mixed": 0.55,
    "FP8-Mixed": 1.0,
}

PREQUANTIZED_PREFIXES = (
    "AWQ-", "GPTQ-", "mlx-", "FP8", "FP4", "NVFP4", "MXFP4", "NF4",
    "INT4", "INT8", "W4A16", "W8A8", "W8A16",
    "FP4-MoE-Mixed", "FP8-Mixed",
)

GPU_BANDWIDTH = {
    "5090": 1792, "5080": 960, "5070 ti": 896, "5070": 672, "5060 ti": 448, "5060": 256,
    "4090": 1008, "4080 super": 736, "4080": 717, "4070 ti super": 672, "4070 ti": 504, "4070 super": 504, "4070": 504, "4060 ti": 288, "4060": 272,
    "3090 ti": 1008, "3090": 936, "3080 ti": 912, "3080": 760, "3070 ti": 608, "3070": 448, "3060 ti": 448, "3060": 360,
    "2080 ti": 616, "2080 super": 496, "2080": 448, "2070 super": 448, "2070": 448, "2060 super": 448, "2060": 336,
    "1660 ti": 288, "1660 super": 336, "1660": 192, "1650 super": 192, "1650": 128,
    "h100 sxm": 3350, "h100": 2039, "h200": 4800, "a100 sxm": 2039, "a100": 1555,
    "l40s": 864, "l40": 864, "l4": 300, "a10g": 600, "a10": 600, "t4": 320,
    "v100 sxm": 900, "v100": 897, "a6000": 768, "a5000": 768, "a4000": 448,
    "7900 xtx": 960, "7900 xt": 800, "7900 gre": 576, "7800 xt": 624, "7700 xt": 432, "7600": 288,
    "6950 xt": 576, "6900 xt": 512, "6800 xt": 512, "6800": 512, "6700 xt": 384, "6600 xt": 256, "6600": 224,
    "mi300x": 5300, "mi300": 5300, "mi250x": 3277, "mi250": 3277, "mi210": 1638, "mi100": 1229,
    "9070 xt": 624, "9070": 488, "9060 xt": 322, "9060": 322,
    "m1 ultra": 800, "m1 max": 400, "m1 pro": 200, "m1": 68,
    "m2 ultra": 800, "m2 max": 400, "m2 pro": 200, "m2": 100,
    "m3 ultra": 800, "m3 max": 300, "m3 pro": 150, "m3": 100,
    "m4 max": 546, "m4 pro": 273, "m4": 120,
    "m5 max": 546, "m5 pro": 273, "m5": 150,
}

_BW_KEYS_SORTED = sorted(GPU_BANDWIDTH.keys(), key=len, reverse=True)

FALLBACK_K = {"cuda": 220, "rocm": 180, "metal": 150, "vulkan": 180, "cpu_x86": 70, "cpu_arm": 90}

USE_CASE_WEIGHTS = {
    "general":    (0.45, 0.30, 0.15, 0.10),
    "coding":     (0.50, 0.20, 0.15, 0.15),
    "reasoning":  (0.55, 0.15, 0.15, 0.15),
    "chat":       (0.40, 0.35, 0.15, 0.10),
    "multimodal": (0.50, 0.20, 0.15, 0.15),
}

SPEED_TARGET = {
    "general": 40, "coding": 40, "multimodal": 40, "chat": 40, "reasoning": 25,
}

CONTEXT_TARGET = {
    "general": 4096, "chat": 4096, "coding": 8192, "reasoning": 8192, "multimodal": 4096,
}

# Embedded reference models fallback catalog
EMBEDDED_MODELS = [
    {
        "name": "Qwen/Qwen2.5-1.5B-Instruct",
        "provider": "Qwen",
        "parameter_count": "1.5B",
        "parameters_raw": 1540000000,
        "context_length": 32768,
        "use_case": "chat",
        "architecture": "qwen2",
        "gguf_sources": [{"repo": "Qwen/Qwen2.5-1.5B-Instruct-GGUF"}]
    },
    {
        "name": "Qwen/Qwen2.5-Coder-7B-Instruct",
        "provider": "Qwen",
        "parameter_count": "7B",
        "parameters_raw": 7250000000,
        "context_length": 32768,
        "use_case": "coding",
        "architecture": "qwen2",
        "gguf_sources": [{"repo": "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF"}]
    },
    {
        "name": "meta-llama/Llama-3.1-8B-Instruct",
        "provider": "meta",
        "parameter_count": "8B",
        "parameters_raw": 8030000000,
        "context_length": 131072,
        "use_case": "chat",
        "architecture": "llama",
        "gguf_sources": [{"repo": "meta-llama/Llama-3.1-8B-Instruct-GGUF"}]
    },
    {
        "name": "deepseek-ai/DeepSeek-R1-Distill-Qwen-14B",
        "provider": "deepseek",
        "parameter_count": "14B",
        "parameters_raw": 14200000000,
        "context_length": 131072,
        "use_case": "reasoning",
        "architecture": "qwen2",
        "gguf_sources": [{"repo": "unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF"}]
    },
    {
        "name": "deepseek-ai/DeepSeek-R1-Distill-Qwen-32B",
        "provider": "deepseek",
        "parameter_count": "32B",
        "parameters_raw": 32500000000,
        "context_length": 131072,
        "use_case": "reasoning",
        "architecture": "qwen2",
        "gguf_sources": [{"repo": "unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF"}]
    },
    {
        "name": "meta-llama/Llama-3.3-70B-Instruct",
        "provider": "meta",
        "parameter_count": "70B",
        "parameters_raw": 70500000000,
        "context_length": 131072,
        "use_case": "chat",
        "architecture": "llama",
        "gguf_sources": [{"repo": "meta-llama/Llama-3.3-70B-Instruct-GGUF"}]
    },
    {
        "name": "deepseek-ai/DeepSeek-R1-Distill-Llama-70B",
        "provider": "deepseek",
        "parameter_count": "70B",
        "parameters_raw": 70500000000,
        "context_length": 131072,
        "use_case": "reasoning",
        "architecture": "llama",
        "gguf_sources": [{"repo": "unsloth/DeepSeek-R1-Distill-Llama-70B-GGUF"}]
    },
    {
        "name": "deepseek-ai/DeepSeek-R1",
        "provider": "deepseek",
        "parameter_count": "671B",
        "parameters_raw": 671000000000,
        "context_length": 163840,
        "use_case": "reasoning",
        "architecture": "deepseek_v3",
        "is_moe": True,
        "num_experts": 257,
        "active_experts": 6,
        "active_parameters": 3700000000,
        "gguf_sources": [{"repo": "unsloth/DeepSeek-R1-GGUF"}]
    }
]

# ── HARDWARE DETECTION LOGIC ──────────────────────────────────────────────────

def _run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return None

def _group_gpus(gpus):
    groups = {}
    order = []
    for g in gpus:
        key = (g["name"], round(g["vram_gb"]))
        if key not in groups:
            groups[key] = {
                "name": g["name"],
                "vram_each": round(g["vram_gb"], 1),
                "count": 0,
                "indices": [],
            }
            order.append(key)
        groups[key]["count"] += 1
        groups[key]["indices"].append(g.get("index"))
    out = []
    for key in order:
        grp = groups[key]
        grp["vram_total"] = round(grp["vram_each"] * grp["count"], 1)
        out.append(grp)
    out.sort(key=lambda x: x["vram_total"], reverse=True)
    return out

def _detect_nvidia():
    out = _run(["nvidia-smi", "--query-gpu=memory.total,name", "--format=csv,noheader,nounits"])
    if not out:
        for _p in NVIDIA_PATH_CANDIDATES:
            out = _run([_p, "--query-gpu=memory.total,name", "--format=csv,noheader,nounits"])
            if out:
                break
    if not out:
        return None

    _low = out.lower()
    if ("nvml" in _low or "driver/library version mismatch" in _low
            or "couldn't communicate" in _low or "no devices were found" in _low
            or "failed to initialize" in _low):
        return {"error": out.strip().split("\n")[0][:140] or "NVIDIA driver error"}

    gpus = []
    unified = []
    for idx, line in enumerate(out.strip().split("\n")):
        parts = [p.strip() for p in line.split(",")]
        if len(parts) >= 2:
            try:
                vram_mb = float(parts[0])
                gpus.append({"index": idx, "name": parts[1], "vram_gb": vram_mb / 1024.0})
            except ValueError:
                if parts[1]:
                    unified.append({"index": idx, "name": parts[1]})
                continue

    if not gpus:
        if unified:
            ram_gb = round(_get_ram_gb(), 1)
            gpus = [{"index": g["index"], "name": g["name"], "vram_gb": ram_gb} for g in unified]
            return {
                "gpu_name": gpus[0]["name"],
                "gpu_vram_gb": ram_gb,
                "gpu_count": len(gpus),
                "gpus": gpus,
                "gpu_groups": _group_gpus(gpus),
                "homogeneous": True,
                "backend": "cuda",
                "unified_memory": True,
            }
        return None
        
    total_vram = sum(g["vram_gb"] for g in gpus)
    groups = _group_gpus(gpus)
    return {
        "gpu_name": gpus[0]["name"],
        "gpu_vram_gb": round(total_vram, 1),
        "gpu_count": len(gpus),
        "gpus": gpus,
        "gpu_groups": groups,
        "homogeneous": len(groups) <= 1,
        "backend": "cuda",
    }

def classify_amd_gfx(gfx):
    gfx = (gfx or "").lower().strip()
    m = re.fullmatch(r"gfx(\d+[a-f]?)", gfx)
    if not m:
        return "", "unknown"
    digits = m.group(1)
    if digits[:2] in ("10", "11", "12"):
        return gfx, "rdna"
    if digits in ("908", "90a") or digits[:2] in ("94", "95"):
        return gfx, "cdna"
    if digits[:1] == "9":
        return gfx, "gcn"
    return gfx, "unknown"

def _detect_amd():
    def _read(path):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                return f.read().strip()
        except Exception:
            return None

    def _list_drm_cards():
        try:
            return [e for e in os.listdir("/sys/class/drm") if e.startswith("card") and "-" not in e]
        except Exception:
            return []

    def _amd_arch():
        info = _run(["rocminfo"]) or _run(["/opt/rocm/bin/rocminfo"]) or ""
        m = re.search(r"gfx\d+[a-f]?", info)
        return classify_amd_gfx(m.group(0) if m else "")

    try:
        cards = []
        is_apu = False
        for _cidx, entry in enumerate(_list_drm_cards()):
            base = f"/sys/class/drm/{entry}/device"
            vendor = _read(f"{base}/vendor")
            if vendor != "0x1002":
                continue
            vram_raw = _read(f"{base}/mem_info_vram_total")
            vis_raw = _read(f"{base}/mem_info_vis_vram_total")
            gtt_raw = _read(f"{base}/mem_info_gtt_total")
            vram_val = int(vram_raw) if vram_raw and vram_raw.isdigit() else 0
            vis_val = int(vis_raw) if vis_raw and vis_raw.isdigit() else 0
            gtt_val = int(gtt_raw) if gtt_raw and gtt_raw.isdigit() else 0
            vram_bytes = max(vram_val, vis_val)
            if vram_bytes <= 0:
                vram_bytes = gtt_val
            if vis_val and vis_val >= vram_val:
                is_apu = True
            if vram_bytes <= 0:
                continue
            name = _read(f"{base}/product_name") or f"AMD GPU ({entry})"
            cards.append({"index": _cidx, "name": name, "vram_gb": vram_bytes / (1024**3)})

        if not cards:
            return None
            
        total_vram = sum(c["vram_gb"] for c in cards)
        groups = _group_gpus(cards)
        gfx, family = _amd_arch()
        return {
            "gpu_name": cards[0]["name"],
            "gpu_vram_gb": round(total_vram, 1),
            "gpu_count": len(cards),
            "gpus": cards,
            "gpu_groups": groups,
            "homogeneous": len(groups) <= 1,
            "backend": "rocm",
            "unified_memory": is_apu,
            "gpu_arch": gfx,
            "gpu_family": family,
        }
    except Exception:
        return None

def _detect_apple_silicon():
    if platform.system() != "Darwin":
        return None
    arch = platform.machine().lower()
    if "arm" not in arch and "aarch64" not in arch:
        return None

    brand = (_run(["sysctl", "-n", "machdep.cpu.brand_string"]) or "Apple Silicon").strip()
    memsize = _run(["sysctl", "-n", "hw.memsize"])
    try:
        total_gb = int(memsize) / (1024**3) if memsize else 0.0
    except ValueError:
        total_gb = 0.0
    if total_gb <= 0:
        return None

    if total_gb <= 16:
        frac = 0.67
    elif total_gb <= 64:
        frac = 0.75
    else:
        frac = 0.80
    vram_gb = round(total_gb * frac, 1)
    
    wired = _run(["sysctl", "-n", "iogpu.wired_limit_mb"])
    try:
        wired_mb = int(wired) if wired else 0
        if wired_mb > 0:
            vram_gb = round(wired_mb / 1024.0, 1)
    except ValueError:
        pass

    gpu = {"index": 0, "name": brand, "vram_gb": vram_gb}
    return {
        "gpu_name": brand,
        "gpu_vram_gb": vram_gb,
        "gpu_count": 1,
        "gpus": [gpu],
        "gpu_groups": _group_gpus([gpu]),
        "homogeneous": True,
        "backend": "metal",
        "unified_memory": True,
    }

def _parse_meminfo():
    if not os.path.exists("/proc/meminfo"):
        return {}
    result = {}
    try:
        with open("/proc/meminfo", encoding="utf-8", errors="replace") as f:
            for line in f:
                if ":" in line:
                    key, val = line.split(":", 1)
                    parts = val.strip().split()
                    if parts:
                        try:
                            result[key.strip()] = int(parts[0])
                        except ValueError:
                            pass
    except Exception:
        pass
    return result

def _get_ram_gb():
    meminfo = _parse_meminfo()
    if "MemTotal" in meminfo:
        return meminfo["MemTotal"] / (1024**2)

    if hasattr(os, "sysconf") and "SC_PHYS_PAGES" in getattr(os, "sysconf_names", {}):
        try:
            pages = os.sysconf("SC_PHYS_PAGES")
            page_size = os.sysconf("SC_PAGE_SIZE")
            if pages and page_size:
                return (pages * page_size) / (1024**3)
        except Exception:
            pass

    memsize = _run(["sysctl", "-n", "hw.memsize"])
    if memsize:
        try:
            return int(memsize.strip()) / (1024**3)
        except ValueError:
            pass
    return 0.0

def _get_available_ram_gb():
    meminfo = _parse_meminfo()
    if "MemAvailable" in meminfo:
        return meminfo["MemAvailable"] / (1024**2)
    return _get_ram_gb() * 0.7

def _get_cpu_name():
    if os.path.exists("/proc/cpuinfo"):
        try:
            with open("/proc/cpuinfo", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("model name"):
                        return line.split(":", 1)[1].strip()
        except Exception:
            pass

    brand = _run(["sysctl", "-n", "machdep.cpu.brand_string"])
    if brand and brand.strip():
        return brand.strip()

    return platform.processor() or "unknown"

def _get_cpu_count():
    return os.cpu_count() or 1

def _powershell_exe():
    return shutil.which("pwsh") or shutil.which("powershell") or "powershell"

def _check_vulkan_working() -> bool:
    """Checks if Vulkan is actually working and can enumerate physical devices on Windows."""
    try:
        import ctypes
        
        class VkApplicationInfo(ctypes.Structure):
            _fields_ = [
                ("sType", ctypes.c_int),
                ("pNext", ctypes.c_void_p),
                ("pApplicationName", ctypes.c_char_p),
                ("applicationVersion", ctypes.c_uint32),
                ("pEngineName", ctypes.c_char_p),
                ("engineVersion", ctypes.c_uint32),
                ("apiVersion", ctypes.c_uint32),
            ]
            
        class VkInstanceCreateInfo(ctypes.Structure):
            _fields_ = [
                ("sType", ctypes.c_int),
                ("pNext", ctypes.c_void_p),
                ("flags", ctypes.c_int),
                ("pApplicationInfo", ctypes.c_void_p),
                ("enabledLayerCount", ctypes.c_uint32),
                ("ppEnabledLayerNames", ctypes.c_void_p),
                ("enabledExtensionCount", ctypes.c_uint32),
                ("ppEnabledExtensionNames", ctypes.c_void_p),
            ]
            
        VkInstance = ctypes.c_void_p
        
        # Suppress Windows error dialog popups during dll loads
        SEM_FAILCRITICALERRORS = 0x0001
        SEM_NOOPENFILEERRORBOX = 0x8000
        old_mode = ctypes.windll.kernel32.SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX)
        try:
            vulkan = ctypes.windll.LoadLibrary("vulkan-1.dll")
        finally:
            ctypes.windll.kernel32.SetErrorMode(old_mode)
            
        if not vulkan:
            return False
            
        vkCreateInstance = vulkan.vkCreateInstance
        vkCreateInstance.argtypes = [ctypes.POINTER(VkInstanceCreateInfo), ctypes.c_void_p, ctypes.POINTER(VkInstance)]
        vkCreateInstance.restype = ctypes.c_int
        
        vkEnumeratePhysicalDevices = vulkan.vkEnumeratePhysicalDevices
        vkEnumeratePhysicalDevices.argtypes = [VkInstance, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
        vkEnumeratePhysicalDevices.restype = ctypes.c_int
        
        vkDestroyInstance = vulkan.vkDestroyInstance
        vkDestroyInstance.argtypes = [VkInstance, ctypes.c_void_p]
        vkDestroyInstance.restype = None
        
        app_info = VkApplicationInfo(
            sType=18,
            pNext=None,
            pApplicationName=b"VulkanCheck",
            applicationVersion=1,
            pEngineName=b"NoEngine",
            engineVersion=1,
            apiVersion=0x00400000
        )
        
        create_info = VkInstanceCreateInfo(
            sType=42,
            pNext=None,
            flags=0,
            pApplicationInfo=ctypes.cast(ctypes.pointer(app_info), ctypes.c_void_p),
            enabledLayerCount=0,
            ppEnabledLayerNames=None,
            enabledExtensionCount=0,
            ppEnabledExtensionNames=None
        )
        
        instance = VkInstance()
        res = vkCreateInstance(ctypes.pointer(create_info), None, ctypes.pointer(instance))
        if res != 0 or not instance:
            return False
            
        try:
            count = ctypes.c_uint32(0)
            res = vkEnumeratePhysicalDevices(instance, ctypes.pointer(count), None)
            if res == 0 and count.value > 0:
                return True
        finally:
            vkDestroyInstance(instance, None)
    except Exception:
        pass
    return False

def _detect_windows():
    ps_cmd = (
        """
        $r = @{}
        $os = Get-CimInstance Win32_OperatingSystem
        $r.ram_gb = [math]::Round($os.TotalVisibleMemorySize / 1048576, 1)
        $r.avail_gb = [math]::Round($os.FreePhysicalMemory / 1048576, 1)
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $r.cpu_name = $cpu.Name
        $r.cpu_cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        $r.arch = $cpu.AddressWidth
        try { 
            $nv = nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -eq 0 -and $nv) { 
                $gpus = @()
                foreach ($line in $nv -split "`n") { 
                    $p = $line -split ','
                    if ($p.Count -ge 2) { $gpus += [pscustomobject]@{name = $p[1].Trim(); vram_mb = [double]$p[0].Trim() } } 
                }
                $r.gpu_name = $gpus[0].name
                $r.gpu_vram_gb = [math]::Round(($gpus | Measure-Object -Property vram_mb -Sum).Sum / 1024, 1)
                $r.gpu_count = $gpus.Count
                $r.gpu_backend = 'cuda'
            } 
        }
        catch {}
        if (-not $r.gpu_name) { 
            $wmiGpu = Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterRAM -gt 0 } | Select-Object -First 1
            if ($wmiGpu) {
                $GPUDriverKey = "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}\\0*"
                $GPUDeviceID = $wmiGpu.PNPDeviceID.Split('&')[0..1] -join '&'
                $VRAMfromRegistry = Get-ItemProperty -Path $GPUDriverKey -ErrorAction SilentlyContinue |
                Where-Object { $_.MatchingDeviceId -like "${GPUDeviceID}*" } |
                Select-Object -ExpandProperty HardwareInformation.qwMemorySize -ErrorAction SilentlyContinue -First 1
                
                $r.gpu_name = $wmiGpu.Name
                if ($VRAMfromRegistry -ge $wmiGpu.AdapterRAM) {
                    $r.gpu_vram_gb = [math]::Round($VRAMfromRegistry / 1073741824, 1)
                }
                else {
                    $r.gpu_vram_gb = [math]::Round($wmiGpu.AdapterRAM / 1073741824, 1)
                }
                $r.gpu_count = 1
                $r.gpu_backend = 'cpu_x86'
            } 
        }
        $r | ConvertTo-Json -Compress
        """
    )
    out = _run([_powershell_exe(), "-NoProfile", "-NonInteractive", "-Command", ps_cmd])
    if not out:
        return None
        
    try:
        d = json.loads(out)
        def _as_int(v, default):
            try:
                return int(v)
            except (TypeError, ValueError):
                return default
                
        _cpu_name = (d.get("cpu_name") or "unknown")
        if isinstance(_cpu_name, str):
            _cpu_name = _cpu_name.strip() or "unknown"
            
        result = {
            "total_ram_gb": d.get("ram_gb", 0),
            "available_ram_gb": d.get("avail_gb", 0),
            "cpu_cores": _as_int(d.get("cpu_cores"), 1),
            "cpu_name": _cpu_name,
            "has_gpu": bool(d.get("gpu_name")),
            "gpu_name": d.get("gpu_name"),
            "gpu_vram_gb": d.get("gpu_vram_gb"),
            "gpu_count": _as_int(d.get("gpu_count"), 0),
            "backend": d.get("gpu_backend", "cpu_x86"),
            "homogeneous": True,
            "gpu_error": None,
            "platform": "windows",
        }
        
        _n = result["gpu_count"] or 0
        if result["has_gpu"] and _n > 0:
            _each = round((result["gpu_vram_gb"] or 0) / _n, 1)
            result["gpus"] = [
                {"index": i, "name": result["gpu_name"], "vram_gb": _each} for i in range(_n)
            ]
            result["gpu_groups"] = [{
                "name": result["gpu_name"],
                "vram_each": _each,
                "count": _n,
                "indices": list(range(_n)),
                "vram_total": result["gpu_vram_gb"],
            }]
            result["homogeneous"] = True
            
        # Check if CUDA DLLs are actually loadable on Windows.
        # If nvidia-smi claims CUDA is the backend, but the runtime DLLs are missing, fallback to Vulkan.
        if result.get("backend") == "cuda":
            cuda_ok = False
            try:
                import ctypes
                SEM_FAILCRITICALERRORS = 0x0001
                SEM_NOOPENFILEERRORBOX = 0x8000
                old_mode = ctypes.windll.kernel32.SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX)
                try:
                    h = ctypes.windll.kernel32.LoadLibraryW("cublas64_12.dll")
                    if h:
                        cuda_ok = True
                        ctypes.windll.kernel32.FreeLibrary(h)
                finally:
                    ctypes.windll.kernel32.SetErrorMode(old_mode)
            except Exception:
                pass
                
            if not cuda_ok:
                result["backend"] = "vulkan"

        # Check if Vulkan is actually functional if it is selected as the backend.
        # Vulkan physical device enumeration can fail or return errors (e.g. inside RDP sessions),
        # which causes llama-server.exe to crash on startup. In this case, fallback to cpu_x86.
        if result.get("backend") == "vulkan":
            if not _check_vulkan_working():
                result["backend"] = "cpu_x86"
                
        return result
    except Exception:
        return None

def detect_system():
    if os.name == "nt":
        result = _detect_windows()
        if result:
            return result

    total_ram = round(_get_ram_gb(), 1)
    available_ram = round(_get_available_ram_gb(), 1)
    cpu_cores = _get_cpu_count()
    cpu_name = _get_cpu_name()

    gpu_info = _detect_apple_silicon() or _detect_nvidia() or _detect_amd()

    if gpu_info and isinstance(gpu_info, dict) and "error" in gpu_info:
        gpu_err = gpu_info["error"]
        gpu_info = None
    else:
        gpu_err = None

    if gpu_info:
        result = {
            "total_ram_gb": total_ram,
            "available_ram_gb": available_ram,
            "cpu_cores": cpu_cores,
            "cpu_name": cpu_name,
            "has_gpu": True,
            "gpu_name": gpu_info["gpu_name"],
            "gpu_vram_gb": gpu_info["gpu_vram_gb"],
            "gpu_count": gpu_info["gpu_count"],
            "gpus": gpu_info.get("gpus", []),
            "gpu_groups": gpu_info.get("gpu_groups", []),
            "homogeneous": gpu_info.get("homogeneous", True),
            "backend": gpu_info["backend"],
            "unified_memory": gpu_info.get("unified_memory", False),
            "gpu_error": None,
            "platform": platform.system().lower(),
        }
        if "gpu_arch" in gpu_info:
            result["gpu_arch"] = gpu_info["gpu_arch"]
        if "gpu_family" in gpu_info:
            result["gpu_family"] = gpu_info["gpu_family"]
    else:
        arch_out = platform.machine().lower()
        backend = "cpu_arm" if "aarch64" in arch_out or "arm" in arch_out else "cpu_x86"
        result = {
            "total_ram_gb": total_ram,
            "available_ram_gb": available_ram,
            "cpu_cores": cpu_cores,
            "cpu_name": cpu_name,
            "has_gpu": False,
            "gpu_name": None,
            "gpu_vram_gb": None,
            "gpu_count": 0,
            "gpus": [],
            "gpu_groups": [],
            "homogeneous": True,
            "backend": backend,
            "unified_memory": False,
            "gpu_error": gpu_err,
            "platform": platform.system().lower(),
        }
    return result

# ── MODEL SCORING & FITTING LOGIC ─────────────────────────────────────────────

def params_b(model):
    raw = model.get("parameters_raw")
    if raw and raw > 0:
        return raw / 1_000_000_000.0

    pc = model.get("parameter_count", "")
    if pc:
        pc = pc.strip().upper()
        m = re.match(r"^([\d.]+)\s*([BKMGT]?)$", pc)
        if m:
            try:
                val = float(m.group(1))
            except ValueError:
                return 0.0
            suffix = m.group(2)
            if suffix == "B":
                return val
            elif suffix == "M":
                return val / 1000.0
            elif suffix == "K":
                return val / 1_000_000.0
            elif suffix == "T":
                return val * 1000.0
            else:
                if val >= 1_000_000:
                    return val / 1_000_000_000.0
                return val / 1000.0
    return 0.0

def _active_params_b(model):
    if model.get("is_moe") and model.get("active_parameters"):
        return model["active_parameters"] / 1_000_000_000.0
    return params_b(model)

def is_prequantized(model):
    q = model.get("quantization", "")
    name = (model.get("name") or "").lower()
    fmt = (model.get("format") or "").lower()
    text = f"{name} {fmt}"
    return (
        "nvfp4" in text
        or re.search(r"(^|[-_/])fp8($|[-_/\s])", text) is not None
        or (not (model.get("is_gguf") or model.get("gguf_sources")) and re.search(r"(^|[-_/])(?:int)?8bit($|[-_/\s])", text) is not None)
        or any(x in text for x in ("awq", "gptq", "mlx"))
        or any(q.startswith(p) for p in PREQUANTIZED_PREFIXES)
    )

def estimate_memory_gb(model, quant, ctx):
    pb = params_b(model)
    bpp = QUANT_BPP.get(quant, 0.58)
    kv_params = _active_params_b(model)
    return pb * bpp + 0.000008 * kv_params * ctx + 0.5

def _lookup_bandwidth(gpu_name):
    if not isinstance(gpu_name, str) or not gpu_name:
        return None
    gn = gpu_name.lower()
    for key in _BW_KEYS_SORTED:
        if key in gn:
            return GPU_BANDWIDTH[key]
    return None

def _estimate_speed(model, quant, run_mode, system, offload_frac=0.0):
    pb = _active_params_b(model)
    is_moe = model.get("is_moe", False)
    bw = _lookup_bandwidth(system.get("gpu_name"))
    backend = system.get("backend", "cpu_x86")

    if bw and run_mode in ("gpu", "cpu_offload"):
        bpp = QUANT_BYTES_PER_PARAM.get(quant, 0.5)
        model_gb = pb * bpp
        if model_gb <= 0:
            return 0.0
        efficiency = 0.55
        if run_mode == "cpu_offload":
            cpu_bw = 55.0
            frac = min(max(offload_frac, 0.0), 1.0)
            if frac <= 0.0:
                frac = 0.5
            eff_bw = 1.0 / (frac / cpu_bw + (1.0 - frac) / bw)
            raw_tps = (eff_bw / model_gb) * efficiency
            return raw_tps * (0.8 if is_moe else 1.0)
        raw_tps = (bw / model_gb) * efficiency
        return raw_tps * (0.8 if is_moe else 1.0)

    k = FALLBACK_K.get(backend, 70)
    if pb <= 0:
        return 0.0
    sm = QUANT_SPEED_MULT.get(quant, 1.0)
    return k / pb * sm

def _architecture_bonus(model):
    name = (model.get("name") or "").lower()
    arch = (model.get("architecture") or "").lower()
    text = f"{name} {arch}"
    if "qwen3.6" in text or "qwen3_6" in text: return 9
    if "qwen3.5" in text or "qwen3_5" in text: return 8
    if "qwen3-next" in text or "qwen3_next" in text: return 6
    if "qwen3" in text or arch.startswith("qwen3"): return 4
    if "qwen2.5" in text or "qwen2_5" in text: return 2
    return 0

def _quality_score(model, quant, use_case):
    pb = params_b(model)
    if pb < 1: base = 30
    elif pb < 3: base = 45
    elif pb < 7: base = 60
    elif pb < 10: base = 75
    elif pb < 20: base = 82
    elif pb < 40: base = 89
    else: base = 95

    name_lower = model.get("name", "").lower()
    if "qwen" in name_lower: base += 2
    if "deepseek" in name_lower: base += 3
    if "llama" in name_lower: base += 2
    if "mistral" in name_lower or "mixtral" in name_lower: base += 1
    if "gemma" in name_lower: base += 1

    base += _architecture_bonus(model)
    base += QUANT_QUALITY_PENALTY.get(quant, 0)

    model_uc = model.get("use_case", "general").lower()
    if model_uc == "coding" and use_case == "coding":
        base += 6
    elif model_uc == "coding" and use_case in ("general", "chat"):
        base -= 10
    if model_uc == "reasoning" and use_case == "reasoning" and pb >= 13:
        base += 5
    elif model_uc == "reasoning" and use_case == "chat":
        base -= 4

    return max(0, min(100, base))

def _speed_score(tps, use_case):
    target = SPEED_TARGET.get(use_case, 40)
    return max(0, min(100, (tps / target) * 100))

def _fit_score(required, available):
    if required > available or available <= 0:
        return 0
    ratio = required / available
    if ratio <= 0.5: return 60 + (ratio / 0.5) * 40
    if ratio <= 0.8: return 100
    if ratio <= 0.9: return 70
    return 50

def _context_score(ctx, use_case):
    target = CONTEXT_TARGET.get(use_case, 4096)
    if ctx >= target: return 100
    if ctx >= target / 2: return 70
    return 30

def _try_quant_at(model, quant, ctx, gpu_vram, available_ram):
    mem = estimate_memory_gb(model, quant, ctx)
    if gpu_vram > 0 and mem <= gpu_vram:
        return "gpu", quant, ctx, mem
    if gpu_vram > 0 and mem <= available_ram:
        return "cpu_offload", quant, ctx, mem
    if gpu_vram <= 0 and mem <= available_ram:
        return "cpu_only", quant, ctx, mem

    cur_ctx = ctx // 2
    while cur_ctx >= 1024:
        mem = estimate_memory_gb(model, quant, cur_ctx)
        if gpu_vram > 0 and mem <= gpu_vram:
            return "gpu", quant, cur_ctx, mem
        if mem <= available_ram:
            return ("cpu_offload" if gpu_vram > 0 else "cpu_only"), quant, cur_ctx, mem
        cur_ctx //= 2
    return None

def _native_quant(model):
    native_quant = model.get("quantization", "Q4_K_M")
    name = (model.get("name") or "").lower()
    fmt = (model.get("format") or "").lower()
    text = f"{name} {fmt}"
    if "nvfp4" in text: return "NVFP4"
    if re.search(r"(^|[-_/])fp8($|[-_/\s])", text): return "FP8"
    if "gptq" in text:
        m = re.search(r"(?:gptq|int|w)(?:[-_]?)(\d{1,2})(?:bit)?", text)
        return f"GPTQ-Int{m.group(1)}" if m else "GPTQ-Int4"
    if "awq" in text:
        m = re.search(r"(?:awq|int|w)(?:[-_]?)(\d{1,2})(?:bit)?", text)
        return f"AWQ-{m.group(1)}bit" if m else "AWQ-4bit"
    return native_quant

def analyze_model(model, system, target_quant=None, scoring_use_case=None, target_context=None):
    pb = params_b(model)
    if pb <= 0:
        return None

    score_use_case = scoring_use_case or "general"
    has_gpu = system.get("has_gpu", False)
    gpu_vram = (system.get("gpu_vram_gb") or 0) if has_gpu else 0
    gpu_count = system.get("gpu_count", 1) or 1
    single_gpu_vram = gpu_vram / gpu_count if gpu_count > 1 else gpu_vram
    available_ram = system.get("available_ram_gb", 0)

    model_ctx = model.get("context_length", 4096) or 4096
    try:
        target_context = int(target_context or 0)
    except (TypeError, ValueError):
        target_context = 0
    ctx = min(model_ctx, target_context) if target_context > 0 else model_ctx

    native_quant = _native_quant(model)
    preq = is_prequantized(model)

    # single GPU limit for dense / GGUFs
    is_gguf = bool(model.get("gguf_sources"))
    if is_gguf and not preq:
        effective_vram = single_gpu_vram
    else:
        effective_vram = gpu_vram

    quant_to_try = target_quant or "Q4_K_M"

    result = _try_quant_at(model, quant_to_try, ctx, effective_vram, available_ram)
    if result is None:
        oversized_required = estimate_memory_gb(model, quant_to_try, ctx)
        return {
            "name": model.get("name"),
            "provider": model.get("provider"),
            "params_b": round(pb, 1),
            "fit_level": "too_tight",
            "run_mode": "no_fit",
            "quant": quant_to_try,
            "context": ctx,
            "required_gb": round(oversized_required, 1),
            "speed_tps": 0,
            "score": 0,
            "scores": {"quality": 0, "speed": 0, "fit": 0, "context": 0},
        }

    run_mode, quant, fit_ctx, required_gb = result

    budget = effective_vram if run_mode == "gpu" else available_ram
    if run_mode == "gpu":
        rec = model.get("recommended_ram_gb") or required_gb
        if rec <= gpu_vram: fit_level = "perfect"
        elif gpu_vram >= required_gb * 1.2: fit_level = "good"
        else: fit_level = "marginal"
    elif run_mode == "cpu_offload":
        fit_level = "good" if available_ram >= required_gb * 1.2 else "marginal"
    else:
        fit_level = "marginal"

    offload_frac = 0.0
    if run_mode == "cpu_offload" and required_gb > 0 and effective_vram > 0:
        offload_frac = max(0.0, (required_gb - effective_vram) / required_gb)
    
    tps = _estimate_speed(model, quant, run_mode, system, offload_frac=offload_frac)

    q_score = _quality_score(model, quant, score_use_case)
    s_score = _speed_score(tps, score_use_case)
    f_score = _fit_score(required_gb, budget)
    c_score = _context_score(fit_ctx, score_use_case)

    wq, ws, wf, wc = USE_CASE_WEIGHTS.get(score_use_case, (0.45, 0.30, 0.15, 0.10))
    composite = q_score * wq + s_score * ws + f_score * wf + c_score * wc

    return {
        "name": model.get("name"),
        "provider": model.get("provider"),
        "params_b": round(pb, 1),
        "fit_level": fit_level,
        "run_mode": run_mode,
        "quant": quant,
        "context": fit_ctx,
        "required_gb": round(required_gb, 1),
        "speed_tps": round(tps, 1),
        "score": round(composite, 1),
        "scores": {
            "quality": round(q_score, 1),
            "speed": round(s_score, 1),
            "fit": round(f_score, 1),
            "context": round(c_score, 1),
        },
        "gguf_sources": model.get("gguf_sources", [])
    }

def rank_models(system_specs, models_catalog, use_case="general", search=None, limit=10):
    results = []
    for m in models_catalog:
        if search:
            name = m.get("name", "").lower()
            provider = m.get("provider", "").lower()
            if search.lower() not in name and search.lower() not in provider:
                continue
        res = analyze_model(m, system_specs, scoring_use_case=use_case)
        if res:
            results.append(res)
    results.sort(key=lambda r: r["score"], reverse=True)
    return results[:limit]

# ── MAIN RUNNER ───────────────────────────────────────────────────────────────

_GENERIC_TAGS = {
    "transformers", "safetensors", "conversational", "text-generation",
    "image-text-to-text", "text-generation-inference", "endpoints_compatible",
    "autotrain_compatible", "compressed-tensors", "gguf", "mlx", "vllm", "4-bit",
    "8-bit", "awq", "gptq", "fp8", "fp4", "nvfp4", "mxfp4", "nf4",
    "quantized", "chat",
}

def parse_params_from_name(name):
    base = name.split("/")[-1]
    active = None
    m_active = re.search(r"-[Aa](\d+\.?\d*)[Bb](?![a-zA-Z])", base)
    if m_active:
        try:
            active = int(float(m_active.group(1)) * 1e9)
        except Exception:
            pass
        base_wo = base[:m_active.start()] + base[m_active.end():]
    else:
        base_wo = base
    total = None
    for m in re.finditer(r"(\d+\.?\d*)[Bb](?![a-zA-Z])", base_wo):
        try:
            total = int(float(m.group(1)) * 1e9)
            break
        except Exception:
            pass
    return total, active

def params_from_config(cfg):
    if not isinstance(cfg, dict):
        return None, None
    for key in ("num_parameters", "n_params", "total_params"):
        v = cfg.get(key)
        if isinstance(v, (int, float)) and v > 0:
            return int(v), None
    def _i(key, default=None):
        v = cfg.get(key, default)
        try:
            return int(v) if v is not None else None
        except (TypeError, ValueError):
            return None
    h = _i("hidden_size")
    L = _i("num_hidden_layers")
    if not h or not L:
        return None, None
    vocab = _i("vocab_size") or 0
    ffn = _i("intermediate_size") or (4 * h)
    n_heads = _i("num_attention_heads") or 0
    n_kv = _i("num_key_value_heads") or n_heads
    head_dim = _i("head_dim") or (h // n_heads if n_heads else h)
    
    q_proj = h * (n_heads * head_dim if n_heads else h)
    kv_proj = 2 * h * (n_kv * head_dim if n_kv else h)
    o_proj = (n_heads * head_dim if n_heads else h) * h
    per_layer_attn = q_proj + kv_proj + o_proj
    per_layer_dense_mlp = 3 * h * ffn
    
    n_experts = _i("num_experts") or _i("n_routed_experts") or 0
    n_shared = _i("n_shared_experts") or 0
    n_active = _i("num_experts_per_tok") or 0
    moe_ffn = _i("moe_intermediate_size") or ffn
    first_dense = _i("first_k_dense_replace") or 0
    
    if n_experts > 0 and n_active > 0:
        moe_layers = max(0, L - first_dense)
        dense_layers = L - moe_layers
        per_expert = 3 * h * moe_ffn
        total_mlp = dense_layers * per_layer_dense_mlp + moe_layers * (n_experts + n_shared) * per_expert
        active_mlp = dense_layers * per_layer_dense_mlp + moe_layers * (n_active + n_shared) * per_expert
    else:
        total_mlp = L * per_layer_dense_mlp
        active_mlp = total_mlp
        
    embed = vocab * h
    head = 0 if cfg.get("tie_word_embeddings", True) else vocab * h
    
    total = embed + head + L * per_layer_attn + total_mlp
    active = embed + head + L * per_layer_attn + active_mlp
    if total <= 0:
        return None, None
    if active == total or n_experts == 0:
        return int(total), None
    return int(total), int(active)

def _load_hf_token():
    # 1. Try environment variables
    for key in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        token = (os.environ.get(key) or "").strip()
        if token:
            return token

    # 2. Try launcher_config.json
    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = os.path.join(script_dir, "data", "launcher_config.json")
    if os.path.exists(config_path):
        try:
            with open(config_path, encoding="utf-8") as f:
                config = json.load(f)
                token = config.get("hfToken") or config.get("HF_TOKEN")
                if token:
                    return token.strip()
        except Exception:
            pass

    # 3. Try standard Hugging Face CLI cache paths
    from pathlib import Path
    for token_path in (
        Path.home() / ".cache" / "huggingface" / "token",
        Path.home() / ".huggingface" / "token",
    ):
        try:
            if token_path.exists():
                token = token_path.read_text(encoding="utf-8").strip()
                if token:
                    return token
        except Exception:
            pass
    return ""

def _strip_hf_url(input_str):
    repo = input_str.strip()
    if repo.startswith("hf.co/"):
        repo = repo[6:]
    m = re.match(r"^https?://huggingface\.co/([^/]+\/[^/?#]+)", repo)
    if m:
        repo = m.group(1)
    return repo

def parse_repo_and_pattern(raw_input):
    cleaned = _strip_hf_url(raw_input)
    if ":" in cleaned:
        repo, tag = cleaned.split(":", 1)
        return repo.strip(), f"*{tag.strip()}*"
    return cleaned.strip(), None

def download_hf_model(repo_id_or_url, pattern=None, target_dir="models", token=None, progress_callback=None):
    """
    Downloads weight files from Hugging Face for a given repository.
    Handles GGUF single-file downloads (based on pattern) and full repository downloads.
    Uses standard library only.
    """
    import urllib.request
    import urllib.parse
    import fnmatch
    import time
    
    repo_id, file_pattern = parse_repo_and_pattern(repo_id_or_url)
    if pattern:
        file_pattern = pattern
        
    if not repo_id or "/" not in repo_id:
        raise ValueError(f"Invalid Hugging Face repository ID: '{repo_id}'. Format must be 'org/model-name'.")
        
    if not token:
        token = _load_hf_token()
        
    headers = {'User-Agent': 'Mozilla/5.0'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
        
    print(f"Connecting to Hugging Face API for '{repo_id}'...")
    url = f"https://huggingface.co/api/models/{repo_id}"
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as response:
            if response.status == 200:
                repo_data = json.loads(response.read().decode('utf-8'))
            else:
                raise Exception(f"HTTP Status {response.status}")
    except Exception as e:
        raise Exception(f"Failed to fetch model metadata for '{repo_id}' from Hugging Face: {e}. Check if the model exists, is gated/private, or if your token is valid.")

    siblings = repo_data.get("siblings", [])
    files = [s.get("rfilename") for s in siblings if s.get("rfilename")]
    
    if not files:
        raise Exception(f"No files found in Hugging Face repository '{repo_id}'.")
        
    is_gguf_repo = any(f.endswith(".gguf") for f in files)
    
    download_list = []
    if file_pattern:
        matched = [f for f in files if fnmatch.fnmatch(f.lower(), file_pattern.lower())]
        if not matched:
            matched = [f for f in files if file_pattern.lower() in f.lower()]
        if not matched:
            raise Exception(f"No files in repository '{repo_id}' matched the pattern '{file_pattern}'. Available files: {', '.join(files[:10])}...")
        download_list = matched
    elif is_gguf_repo:
        ggufs = [f for f in files if f.endswith(".gguf")]
        if len(ggufs) == 1:
            download_list = ggufs
        else:
            q4_m = next((f for f in ggufs if "q4_k_m" in f.lower() or "q4_0" in f.lower()), None)
            if q4_m:
                print(f"Auto-selected quant file '{q4_m}' from GGUF repository.")
                download_list = [q4_m]
            else:
                raise Exception(f"Multiple GGUF files found in '{repo_id}'. Please specify a quant tag (e.g. repo_id:Q4_K_M or via pattern). Available files: {', '.join(ggufs[:10])}")
    else:
        core_extensions = (".json", ".txt", ".bin", ".safetensors", ".model", ".py")
        download_list = [f for f in files if any(f.endswith(ext) for ext in core_extensions) or "/" not in f]
        
    is_single_file = len(download_list) == 1
    if is_single_file:
        dest_dir = target_dir
    else:
        folder_name = repo_id.replace("/", "--")
        dest_dir = os.path.join(target_dir, folder_name)
        
    os.makedirs(dest_dir, exist_ok=True)
    print(f"Starting download of {len(download_list)} file(s) to '{dest_dir}'...")
    
    for idx, filename in enumerate(download_list):
        dest_path = os.path.join(dest_dir, filename)
        file_dir = os.path.dirname(dest_path)
        if file_dir:
            os.makedirs(file_dir, exist_ok=True)
            
        file_url = f"https://huggingface.co/{repo_id}/resolve/main/{urllib.parse.quote(filename)}"
        print(f"[{idx+1}/{len(download_list)}] Downloading '{filename}'...")
        
        try:
            req = urllib.request.Request(file_url, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as response:
                total_bytes = int(response.headers.get('content-length', 0))
                
                if os.path.exists(dest_path) and os.path.getsize(dest_path) == total_bytes and total_bytes > 0:
                    print(f"  File '{filename}' already fully downloaded. Skipping.")
                    if progress_callback:
                        progress_callback(filename, total_bytes, total_bytes, 0.0, 100.0)
                    continue
                    
                start_time = time.time()
                downloaded = 0
                chunk_size = 1024 * 1024  # 1MB chunks
                
                temp_path = dest_path + ".downloading"
                with open(temp_path, "wb") as f_out:
                    while True:
                        chunk = response.read(chunk_size)
                        if not chunk:
                            break
                        f_out.write(chunk)
                        downloaded += len(chunk)
                        
                        percent = (downloaded / total_bytes * 100) if total_bytes > 0 else 0
                        elapsed = time.time() - start_time
                        speed_mb = (downloaded / (1024 * 1024)) / elapsed if elapsed > 0 else 0
                        
                        if progress_callback:
                            progress_callback(filename, downloaded, total_bytes, speed_mb, percent)
                        else:
                            _print_cli_progress(filename, downloaded, total_bytes, speed_mb, percent)
                            
                if os.path.exists(dest_path):
                    os.remove(dest_path)
                os.rename(temp_path, dest_path)
                print(f"\n  Successfully downloaded '{filename}'.")
        except Exception as e:
            raise Exception(f"Failed to download file '{filename}' from '{file_url}': {e}")
            
    print(f"Download task for '{repo_id}' finished successfully.")

def _print_cli_progress(filename, downloaded, total, speed, percent):
    dl_mb = downloaded / (1024 * 1024)
    tot_mb = total / (1024 * 1024)
    bar_len = 30
    filled_len = int(round(bar_len * percent / 100)) if total > 0 else 0
    bar = '=' * filled_len + '-' * (bar_len - filled_len)
    sys.stdout.write(f"\r  [{bar}] {percent:.1f}% ({dl_mb:.1f}/{tot_mb:.1f} MB) | {speed:.2f} MB/s | {filename[:25]}")
    sys.stdout.flush()

def fetch_config_json(repo_id):
    import urllib.request
    url = f"https://huggingface.co/{repo_id}/raw/main/config.json"
    try:
        headers = {'User-Agent': 'Mozilla/5.0'}
        token = _load_hf_token()
        if token:
            headers['Authorization'] = f'Bearer {token}'
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as response:
            if response.status == 200:
                return json.loads(response.read().decode('utf-8'))
    except Exception:
        pass
    return None

def model_from_hf_api(item):
    name = item.get("id")
    if not name:
        return None
    provider = name.split("/")[0]
    total, active = parse_params_from_name(name)
    tags = item.get("tags", [])
    
    # Try parent base model tags
    if total is None:
        for tag in tags:
            if tag.startswith("base_model:"):
                bm = tag.split(":")[-1]
                total, act = parse_params_from_name(bm)
                if total:
                    if act and active is None:
                        active = act
                    break
                    
    # Try config
    if total is None:
        cfg = fetch_config_json(name)
        if cfg:
            total, active = params_from_config(cfg)
        else:
            for tag in tags:
                if tag.startswith("base_model:"):
                    bm = tag.split(":")[-1]
                    cfg = fetch_config_json(bm)
                    if cfg:
                        total, active = params_from_config(cfg)
                        break
                        
    if total is None:
        return None
        
    pb = total / 1e9
    quant = _quant_from_name(name)
    
    use_case = "general"
    if "code" in name.lower():
        use_case = "coding"
    elif "reason" in name.lower() or "distill" in name.lower():
        use_case = "reasoning"
        
    created_str = item.get("createdAt", "")
    release_date = created_str.split("T")[0] if created_str else ""
        
    res = {
        "name": name,
        "provider": provider,
        "parameter_count": f"{round(pb, 1)}B",
        "parameters_raw": total,
        "quantization": quant,
        "context_length": 32768,
        "use_case": use_case,
        "architecture": next((t for t in tags if re.fullmatch(r"[a-z0-9_]+", t) and t not in _GENERIC_TAGS and any(c.isalpha() for c in t)), ""),
        "hf_downloads": item.get("downloads", 0),
        "hf_likes": item.get("likes", 0),
        "release_date": release_date,
    }
    if active:
        res["is_moe"] = True
        res["active_parameters"] = active
    return res

def fetch_from_huggingface_api(authors=["cyankiwi"], search=None):
    import urllib.request
    import urllib.parse
    models = []
    
    token = _load_hf_token()
    headers = {'User-Agent': 'Mozilla/5.0'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    
    if search:
        url = f"https://huggingface.co/api/models?search={urllib.parse.quote(search)}&limit=30&full=true"
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=8) as response:
                if response.status == 200:
                    items = json.loads(response.read().decode('utf-8'))
                    for item in items:
                        model_entry = model_from_hf_api(item)
                        if model_entry:
                            models.append(model_entry)
        except Exception as e:
            print(f"Error searching Hugging Face for '{search}': {e}")
            
    for author in authors:
        url = f"https://huggingface.co/api/models?author={author}&full=true"
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=8) as response:
                if response.status == 200:
                    items = json.loads(response.read().decode('utf-8'))
                    for item in items:
                        model_entry = model_from_hf_api(item)
                        if model_entry and not any(m["name"] == model_entry["name"] for m in models):
                            models.append(model_entry)
        except Exception:
            pass
    return models

def get_models_catalog(search=None):
    # Attempt to load from parent or subfolder first
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(script_dir, "odysseus", "services", "hwfit", "data", "hf_models.json"),
        os.path.join(script_dir, "services", "hwfit", "data", "hf_models.json"),
        os.path.join(script_dir, "data", "hf_models.json")
    ]
    loaded_models = []
    for path in candidates:
        if os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as f:
                    models = json.load(f)
                    if models:
                        loaded_models = models
                        break
            except Exception:
                pass

    if not loaded_models:
        # Try downloading dynamically from remote repository
        import urllib.request
        urls = [
            "https://raw.githubusercontent.com/pewdiepie-archdaemon/odysseus/main/services/hwfit/data/hf_models.json",
            "https://raw.githubusercontent.com/pewdiepie-archdaemon/odysseus/master/services/hwfit/data/hf_models.json"
        ]
        for url in urls:
            try:
                req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req, timeout=5) as response:
                    if response.status == 200:
                        models = json.loads(response.read().decode('utf-8'))
                        if models:
                            loaded_models = models
                            break
            except Exception:
                pass

    if not loaded_models:
        print("Catalog file not found. Fetching from Hugging Face API dynamically...")
        loaded_models = fetch_from_huggingface_api(search=search)
    elif search:
        has_match = any(search.lower() in m.get("name", "").lower() for m in loaded_models)
        if not has_match:
            print(f"No match for '{search}' in static catalog. Searching Hugging Face API...")
            hf_models = fetch_from_huggingface_api(search=search)
            for hfm in hf_models:
                if not any(m["name"] == hfm["name"] for m in loaded_models):
                    loaded_models.append(hfm)

    if not loaded_models:
        return EMBEDDED_MODELS
        
    return loaded_models

def apply_cli_overrides(system, args):
    if args.cpu_only or args.gpus == 0:
        system["has_gpu"] = False
        system["gpu_name"] = None
        system["gpu_vram_gb"] = 0.0
        system["gpu_count"] = 0
        system["gpus"] = []
        system["gpu_groups"] = []
        system["backend"] = "cpu_x86"
        system.pop("unified_memory", None)
        
    if args.ram is not None:
        system["available_ram_gb"] = args.ram
        system["total_ram_gb"] = args.ram
        
    if not args.cpu_only and args.gpus is not None and args.gpus > 0:
        system["has_gpu"] = True
        system["gpu_count"] = args.gpus
        vram_each = args.vram
        if vram_each is None:
            if system.get("gpus"):
                vram_each = system["gpus"][0].get("vram_gb", 8.0)
            else:
                vram_each = 8.0
        total_vram = round(vram_each * args.gpus, 1)
        gpu_name = f"Simulated GPU" + (f" x {args.gpus}" if args.gpus > 1 else "")
        system["gpu_name"] = gpu_name
        system["gpu_vram_gb"] = total_vram
        system["gpus"] = [{"index": i, "name": gpu_name, "vram_gb": vram_each} for i in range(args.gpus)]
        system["gpu_groups"] = [{
            "name": gpu_name,
            "vram_each": vram_each,
            "count": args.gpus,
            "indices": list(range(args.gpus)),
            "vram_total": total_vram,
        }]
        system["homogeneous"] = True
        if system.get("backend") in ("cpu_x86", "cpu_arm"):
            system["backend"] = "cuda"
            
    elif not args.cpu_only and args.vram is not None:
        system["has_gpu"] = True
        count = system.get("gpu_count", 1) or 1
        total_vram = round(args.vram * count, 1)
        gpu_name = system.get("gpu_name") or "Simulated GPU"
        system["gpu_vram_gb"] = total_vram
        system["gpus"] = [{"index": i, "name": gpu_name, "vram_gb": args.vram} for i in range(count)]
        system["gpu_groups"] = [{
            "name": gpu_name,
            "vram_each": args.vram,
            "count": count,
            "indices": list(range(count)),
            "vram_total": total_vram,
        }]
        system["homogeneous"] = True
        if system.get("backend") in ("cpu_x86", "cpu_arm"):
            system["backend"] = "cuda"
            
    return system

def generate_serving_command(rec, specs, target_ctx=None):
    if rec.get("run_mode") == "no_fit" or rec.get("fit_level") == "too_tight":
        return "N/A - Model does not fit on the evaluated hardware configuration."
        
    run_mode = rec.get("run_mode", "gpu")
    quant = rec.get("quant", "Q4_K_M")
    context = rec.get("context", 4096)
    if target_ctx is not None:
        context = min(context, target_ctx)
    name = rec.get("name", "model")
    backend = specs.get("backend", "cpu_x86")
    
    # Check if prequantized formats (AWQ, GPTQ, FP8) are used
    is_vllm_format = any(quant.startswith(p) for p in ("AWQ-", "GPTQ-", "FP8", "FP4", "NVFP4"))
    
    if is_vllm_format and backend in ("cuda", "rocm") and run_mode in ("gpu", "cpu_offload"):
        gpu_count = specs.get("gpu_count", 1) or 1
        tp_flag = f" --tensor-parallel-size {gpu_count}" if gpu_count > 1 else ""
        return f"vllm serve {name}{tp_flag} --max-model-len {context}"
        
    # Recomend llama.cpp (llama-cli)
    ngl = 0 if run_mode == "cpu_only" else 999
    moe_flag = ""
    
    is_moe = rec.get("is_moe", False)
    n_cpu_moe = 0
    if is_moe and run_mode == "cpu_offload":
        pb = rec.get("params_b", 7.0)
        layers = 64 if pb >= 60 else (48 if pb >= 25 else (40 if pb >= 12 else 32))
        vram = float(specs.get("gpu_vram_gb") or 0.0)
        is_vision = "vision" in name.lower() or "vl" in name.lower()
        headroom = 1.1 if is_vision else 0.4
        budget = max(vram - headroom, 1.0)
        
        weights = pb * QUANT_BPP.get(quant, 0.58)
        kv_params = rec.get("active_parameters", pb * 1e9) / 1e9
        kv = 0.000008 * kv_params * context * 0.5
        needed = weights + kv + 0.6
        if needed > budget:
            per_layer = weights / max(layers, 1)
            overflow = needed - budget
            import math
            n_cpu_moe = math.ceil(overflow / max(per_layer, 1e-6))
            n_cpu_moe = max(0, min(n_cpu_moe, layers))
            
    if n_cpu_moe > 0:
        moe_flag = f" --n-cpu-moe {n_cpu_moe}"
        
    kv_type = "q8_0" if rec.get("fit_level") == "perfect" else "q4_0"
    kv_flag = f" --cache-type-k {kv_type} --cache-type-v {kv_type}"
    
    filename = name.split("/")[-1].lower()
    gguf_filename = f"{filename}.{quant.lower()}.gguf"
    
    return f"llama-cli -m {gguf_filename} -ngl {ngl} -c {context}{kv_flag}{moe_flag}"

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Standalone Hardware Detector & LLM Model Fit Utility")
    parser.add_argument("-s", "--search", type=str, default=None, help="Search query for model name/provider")
    parser.add_argument("-u", "--use-case", type=str, default=None, choices=["general", "coding", "reasoning", "chat", "multimodal"], help="Weights use-case context")
    parser.add_argument("-c", "--ctx", type=int, default=None, help="Target context length override")
    parser.add_argument("-l", "--limit", type=int, default=5, help="Number of ranked model entries to print")
    parser.add_argument("--gpus", type=int, default=None, help="Override detected GPU count")
    parser.add_argument("--vram", type=float, default=None, help="Override VRAM per GPU (GB)")
    parser.add_argument("--ram", type=float, default=None, help="Override available system RAM (GB)")
    parser.add_argument("--cpu-only", action="store_true", help="Force evaluate using CPU path only")
    parser.add_argument("--command", action="store_true", help="Show CLI terminal commands for model serving recommendations")
    parser.add_argument("--json", action="store_true", help="Format and print all outputs strictly in JSON mode")
    parser.add_argument("--download", type=str, default=None, help="Hugging Face model repository ID or URL to download")
    parser.add_argument("--quant-pattern", type=str, default=None, help="Filter file to download by filename pattern (e.g. *Q4_K_M.gguf)")
    
    args = parser.parse_args()

    if args.download:
        try:
            download_hf_model(args.download, pattern=args.quant_pattern)
            sys.exit(0)
        except Exception as e:
            print(f"\nError: {e}")
            sys.exit(1)

    # 1. Probing specs and applying manual overrides
    specs = detect_system()
    specs = apply_cli_overrides(specs, args)
    
    # 2. Loading model database
    catalog = get_models_catalog(search=args.search)
    
    # 3. Determine scoring cases to evaluate
    use_cases = [args.use_case] if args.use_case else ["general", "coding", "reasoning"]
    
    evaluated_results = {}
    for uc in use_cases:
        recommendations = rank_models(specs, catalog, use_case=uc, search=args.search, limit=args.limit)
        
        # Inject serve commands if requested (or always for JSON exports)
        for rec in recommendations:
            rec["serving_command"] = generate_serving_command(rec, specs, target_ctx=args.ctx)
            
        evaluated_results[uc] = recommendations

    # 4. Printing Output
    if args.json:
        output_data = {
            "hardware": specs,
            "use_case_recommendations": evaluated_results
        }
        print(json.dumps(output_data, indent=2))
    else:
        # Standard stdout printer
        print("--------------------------------------------------")
        print("1. PROBING HARDWARE COMPONENT SPECS...")
        print(json.dumps(specs, indent=2))
        
        print("\n--------------------------------------------------")
        print("2. RANKING AND EVALUATING COMPATIBLE MODELS...")
        if args.search:
            print(f"Filter term: '{args.search}'")
            
        for uc, recommendations in evaluated_results.items():
            print(f"\n>> Top Fit Recommendations for Use Case: '{uc.upper()}'")
            if not recommendations:
                print("   No matching models found.")
                continue
            for idx, rec in enumerate(recommendations):
                status = "[OK]" if rec["fit_level"] in ("perfect", "good") else "[WARN]"
                if rec["fit_level"] == "too_tight":
                    status = "[FAIL]"
                print(f" {idx+1}. {rec['name']} ({rec['params_b']}B params)")
                print(f"    Fit Level: {rec['fit_level'].upper()} {status} | Run Mode: {rec['run_mode'].upper()}")
                print(f"    Required Memory: {rec['required_gb']} GB | Est. Speed: {rec['speed_tps']} tok/s")
                print(f"    Fitness Score: {rec['score']}/100 (Quality: {rec['scores']['quality']}, Speed: {rec['scores']['speed']}, Fit: {rec['scores']['fit']})")
                if args.command:
                    print(f"    Serving Command: {rec['serving_command']}")
                    hf_name = rec['name']
                    if rec.get("gguf_sources") and len(rec["gguf_sources"]) > 0 and rec.get("quant") and rec.get("quant").upper().startswith("Q"):
                        hf_name = rec["gguf_sources"][0]["repo"]
                    print(f"    Download Link:   https://huggingface.co/{hf_name}/tree/main")
        print("--------------------------------------------------")
