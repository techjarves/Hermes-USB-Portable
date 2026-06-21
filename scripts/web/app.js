// DOM Elements
const sections = {
    welcome: document.getElementById('step-welcome'),
    select: document.getElementById('step-select'),
    install: document.getElementById('step-install'),
    success: document.getElementById('step-success')
};

const btnDetect = document.getElementById('btn-detect');
const detectLoading = document.getElementById('detect-loading');
const systemBadge = document.getElementById('system-badge');

// Specs display
const specs = {
    os: document.getElementById('spec-os'),
    cpu: document.getElementById('spec-cpu'),
    gpu: document.getElementById('spec-gpu'),
    backend: document.getElementById('spec-backend')
};

const modelCardsContainer = document.getElementById('model-cards-container');

// Install progress display
const installTitle = document.getElementById('install-title');
const installDesc = document.getElementById('install-desc');
const progressFile = document.getElementById('progress-file');
const progressPercent = document.getElementById('progress-percent');
const progressBarFill = document.getElementById('progress-bar-fill');
const progressDownloaded = document.getElementById('progress-downloaded');
const progressSpeed = document.getElementById('progress-speed');
const consoleLogs = document.getElementById('console-logs');

// Success display
const successModelName = document.getElementById('success-model-name');
const btnFinish = document.getElementById('btn-finish');

// App variables
let systemSpecs = null;
let recommendedModels = [];
let statusInterval = null;

// Navigation helper
function showSection(name) {
    Object.keys(sections).forEach(key => {
        if (key === name) {
            sections[key].classList.add('active');
        } else {
            sections[key].classList.remove('active');
        }
    });
}

// Log utility
function logConsole(message, type = 'info') {
    const line = document.createElement('div');
    line.className = 'log-line';
    
    if (type === 'success') line.classList.add('text-green');
    else if (type === 'warn') line.classList.add('text-yellow');
    else if (type === 'error') line.classList.add('text-red');
    else if (type === 'cyan') line.classList.add('text-cyan');
    
    const timestamp = new Date().toLocaleTimeString();
    line.textContent = `[${timestamp}] ${message}`;
    
    consoleLogs.appendChild(line);
    consoleLogs.scrollTop = consoleLogs.scrollHeight;
}

// Event Listeners
btnDetect.addEventListener('click', async () => {
    btnDetect.classList.add('hidden');
    detectLoading.classList.remove('hidden');
    
    try {
        const response = await fetch('/api/detect');
        const data = await response.json();
        
        systemSpecs = data.system;
        recommendedModels = data.recommendations;
        
        // Populate system specifications
        specs.os.textContent = `${systemSpecs.platform.toUpperCase()} (${systemSpecs.platform === 'windows' ? '64-bit' : systemSpecs.platform})`;
        specs.cpu.textContent = `${systemSpecs.cpu_name} (${systemSpecs.cpu_cores} Cores) | ${Math.round(systemSpecs.total_ram_gb)} GB RAM`;
        specs.gpu.textContent = systemSpecs.has_gpu ? `${systemSpecs.gpu_name} (${Math.round(systemSpecs.gpu_vram_gb)} GB VRAM)` : 'No Dedicated GPU Detected';
        
        // Setup Acceleration Badge
        const backend = systemSpecs.backend.toUpperCase();
        specs.backend.textContent = backend;
        specs.backend.className = 'badge';
        if (backend === 'CUDA' || backend === 'METAL') {
            specs.backend.classList.add('badge-success');
            systemBadge.textContent = `Hardware Acceleration Active: ${backend}`;
            systemBadge.classList.add('text-green');
        } else if (backend.startsWith('CPU')) {
            specs.backend.classList.add('badge-warning');
            systemBadge.textContent = 'CPU Only Mode';
        } else {
            specs.backend.classList.add('badge-accent');
            systemBadge.textContent = `GPU: ${backend}`;
        }
        
        // Populate model recommendations
        renderModelCards();
        
        // Move to Step 2
        showSection('select');
        
    } catch (error) {
        btnDetect.classList.remove('hidden');
        detectLoading.classList.add('hidden');
        alert(`Hardware scan failed: ${error.message}`);
    }
});

function getFitBadgeClass(fitLevel) {
    switch(fitLevel) {
        case 'perfect': return 'badge-success';
        case 'good': return 'badge-accent';
        case 'marginal': return 'badge-warning';
        case 'too_tight': return 'badge-danger';
        default: return 'badge-muted';
    }
}

function getFitLabel(fitLevel) {
    switch(fitLevel) {
        case 'perfect': return 'Highly Recommended';
        case 'good': return 'Runs Good';
        case 'marginal': return 'Slow / Partial GPU';
        case 'too_tight': return 'Too Large for RAM';
        default: return fitLevel;
    }
}

function renderModelCards() {
    modelCardsContainer.innerHTML = '';
    
    recommendedModels.forEach(model => {
        const card = document.createElement('div');
        card.className = `model-card ${model.fit_level}`;
        
        const nameParts = model.name.split('/');
        const shortName = nameParts[nameParts.length - 1];
        
        const fitClass = getFitBadgeClass(model.fit_level);
        const fitLabel = getFitLabel(model.fit_level);
        
        const runModeLabel = model.run_mode === 'gpu' ? 'Entirely on GPU' : 
                             model.run_mode === 'cpu_offload' ? 'GPU Offload' : 'CPU Only';
                             
        const downloadSource = model.gguf_sources && model.gguf_sources.length > 0 ? model.gguf_sources[0].repo : '';
        
        card.innerHTML = `
            <div class="model-main">
                <div class="model-header">
                    <span class="model-name">${shortName}</span>
                    <span class="badge ${fitClass}">${fitLabel}</span>
                    <span class="badge badge-accent">${runModeLabel}</span>
                </div>
                <div class="model-details">
                    <div class="detail-item">💾 <span>Size: ${model.required_gb} GB</span></div>
                    <div class="detail-item">⚡ <span>Speed: ~${model.speed_tps} tok/s</span></div>
                    <div class="detail-item">📚 <span>Context: ${model.context} tokens</span></div>
                </div>
            </div>
            <button class="btn btn-primary btn-select" ${model.fit_level === 'too_tight' ? 'disabled' : ''} data-repo="${downloadSource}" data-name="${shortName}" data-quant="${model.quant || ''}">
                Select & Setup
            </button>
        `;
        
        modelCardsContainer.appendChild(card);
        
        // Bind Select Action
        const btnSelect = card.querySelector('.btn-select');
        btnSelect.addEventListener('click', () => {
            const repo = btnSelect.getAttribute('data-repo');
            const name = btnSelect.getAttribute('data-name');
            const quant = btnSelect.getAttribute('data-quant');
            startInstallation(repo, name, quant);
        });
    });
}

async function startInstallation(modelRepo, modelName, modelQuant) {
    showSection('install');
    logConsole(`Starting setup procedure for ${modelName}...`, 'cyan');
    
    try {
        // STEP A: Download llama-server binaries
        installTitle.textContent = "Downloading llama.cpp Server...";
        progressFile.textContent = "llama-server.zip";
        logConsole(`Sending request to download platform-specific llama.cpp server binaries...`);
        
        const response = await fetch('/api/download-server', { method: 'POST' });
        const startData = await response.json();
        logConsole(`Started download from URL: ${startData.url}`);
        
        // Start status polling
        await runProgressLoop("server");
        logConsole(`llama-server binaries downloaded successfully.`, 'success');
        
        // STEP B: Extract llama-server binaries
        installTitle.textContent = "Extracting llama.cpp Server...";
        logConsole(`Extracting zip file to runtime directory...`);
        progressBarFill.style.width = "100%";
        progressPercent.textContent = "Extracting...";
        
        const extractResp = await fetch('/api/extract-server', { method: 'POST' });
        const extractData = await extractResp.json();
        
        if (extractData.error) {
            throw new Error(`Extraction failed: ${extractData.error}`);
        }
        logConsole(`Extraction complete. Runtime folders created.`, 'success');
        
        // STEP C: Download GGUF model from Hugging Face
        installTitle.textContent = `Downloading ${modelName} GGUF...`;
        progressFile.textContent = `${modelName}`;
        logConsole(`Initiating Hugging Face download for GGUF repository '${modelRepo}'...`);
        
        const payload = { repo_id: modelRepo };
        if (modelQuant) {
            payload.pattern = `*${modelQuant.toLowerCase()}*.gguf`;
        }
        const modelResp = await fetch('/api/download-model', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        
        const modelStartData = await modelResp.json();
        if (modelStartData.error) {
            throw new Error(modelStartData.error);
        }
        
        await runProgressLoop("model");
        logConsole(`Model GGUF file downloaded successfully.`, 'success');
        
        // STEP D: Configure configuration files
        installTitle.textContent = "Writing Configuration Settings...";
        logConsole(`Updating data/config.yaml and data/.env files...`);
        
        // Find local filename
        const statusResponse = await fetch('/api/status');
        const statusData = await statusResponse.json();
        const modelFilename = statusData.download_status.filename;
        
        const configResp = await fetch('/api/configure', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ model_file: modelFilename })
        });
        const configData = await configResp.json();
        if (configData.error) {
            throw new Error(configData.error);
        }
        
        logConsole(`Configuration files saved successfully. Local LLM setup completed.`, 'success');
        
        // Complete! Move to success screen
        successModelName.textContent = modelFilename;
        showSection('success');
        
    } catch (error) {
        logConsole(`INSTALLATION ERROR: ${error.message}`, 'error');
        alert(`Installation failed: ${error.message}. Check console logs.`);
        installTitle.textContent = "Installation Failed";
        installDesc.textContent = "An error occurred during installation. Please check the logs below.";
        progressBarFill.classList.add('bg-danger');
    }
}

function runProgressLoop(expectedType) {
    return new Promise((resolve, reject) => {
        let errorCount = 0;
        let lastPercent = -1;
        
        statusInterval = setInterval(async () => {
            try {
                const res = await fetch('/api/status');
                const state = await res.json();
                
                const ds = state.download_status;
                if (!ds.active && !ds.complete && !ds.error) {
                    // Download hasn't started yet
                    return;
                }
                
                if (ds.error) {
                    clearInterval(statusInterval);
                    reject(new Error(ds.error));
                    return;
                }
                
                if (ds.complete && ds.type === expectedType) {
                    clearInterval(statusInterval);
                    resolve();
                    return;
                }
                
                // Update Progress metrics
                progressPercent.textContent = `${ds.percent}%`;
                progressBarFill.style.width = `${ds.percent}%`;
                
                const dlMB = (ds.downloaded_bytes / (1024 * 1024)).toFixed(1);
                const totMB = (ds.total_bytes / (1024 * 1024)).toFixed(1);
                progressDownloaded.textContent = `${dlMB} MB / ${totMB} MB`;
                progressSpeed.textContent = `${ds.speed_mb} MB/s`;
                
                // Periodic logging in console
                const roundedPercent = Math.floor(ds.percent);
                if (roundedPercent % 10 === 0 && roundedPercent !== lastPercent) {
                    logConsole(`Download Progress: ${roundedPercent}% (${dlMB}/${totMB} MB) at ${ds.speed_mb} MB/s`);
                    lastPercent = roundedPercent;
                }
                
            } catch (err) {
                errorCount++;
                if (errorCount > 10) {
                    clearInterval(statusInterval);
                    reject(new Error("Lost connection to configurator backend."));
                }
            }
        }, 500);
    });
}

btnFinish.addEventListener('click', async () => {
    try {
        logConsole("Shutting down setup server...", "cyan");
        btnFinish.disabled = true;
        btnFinish.textContent = "Launching...";
        
        // Call shutdown API
        await fetch('/api/shutdown', { method: 'POST' });
        
        // Wait and close window
        setTimeout(() => {
            window.close();
            // Fallback display if window.close is blocked by browser security
            document.body.innerHTML = `
                <div class="card" style="max-width: 500px; text-align: center; margin: 50px auto;">
                    <h2>Configuration Server Closed</h2>
                    <p style="color: #9ca3af; margin: 15px 0;">You can now safely close this browser window and return to your terminal launcher.</p>
                </div>
            `;
        }, 1000);
    } catch (e) {
        // Ignore network errors since server is shutting down
        window.close();
    }
});
