# iLLM-PMB: Specification-Grounded LLM-PPO Framework for FWD-Based Pavement Modulus Backcalculation

[![MATLAB](https://img.shields.io/badge/MATLAB-R2024b-blue)](https://www.mathworks.com/products/matlab.html)
[![Python](https://img.shields.io/badge/Python-3.10%2B-green)](https://www.python.org/)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

This repository contains the official implementation of **iLLM-PMB**, a hybrid framework that integrates Large Language Model (LLM) reasoning, Proximal Policy Optimization (PPO), and an explicit specification-grounded knowledge layer for pavement modulus backcalculation from Falling Weight Deflectometer (FWD) measurements.

> **Paper (under review):** *iLLM-PMB: Specification-Grounded LLM-PPO Framework for FWD-Based Pavement Modulus Backcalculation*

---

## Overview

### The Problem

FWD is the industry-standard non-destructive testing device for in-service pavement evaluation. However, converting the measured deflection basin into layer elastic moduli is a classic ill-posed inverse problem: many distinct modulus combinations can produce nearly identical deflection basins (solution non-uniqueness). Existing methods struggle with local optima, computational cost, limited physical interpretability, and reliance on large training datasets.

### Our Approach

iLLM-PMB addresses these challenges through four key innovations:

1. **LLM-PPO Hybrid Optimization**: PPO provides sample-efficient adaptive exploration of the modulus space while periodic LLM guidance injects structure-aware engineering knowledge.

2. **Specification-Grounded Knowledge Layer**: A three-layer architecture that formalizes engineering knowledge from design specifications (JTG D50-2017, ASTM D5858, AASHTO MEPDG) into hard physical boundaries, retrieval-augmented soft guidance, and provenance-aware LLM plausibility adjudication.

3. **Multi-Run with Physical Plausibility Scoring**: Five independent PPO runs generate candidate solutions; an LLM scores each candidate across four physical dimensions (modulus ranges, layer stiffness gradients, basin match quality, engineering applicability), selecting the most physically credible solution rather than the one with minimum mathematical error.

4. **Dual-Mode Input & Model-Agnostic Deployment**: Supports both natural language descriptions and structured numerical inputs; validated with both commercial APIs (DeepSeek-V3) and open-source models (Qwen2.5-7B via Ollama).

### Key Results

- **100% convergence** on 12 synthetic structures (mean D₀ error: 1.69 ± 0.69%)
- **Mean modulus error of 14.3%** vs. 36.9% (In-Simu) and 41.2% (MODULUS 6.0)
- **27.8 percentage-point convergence gain** from explicit specification knowledge (44.4% → 72.2%)
- **37% fewer PPO iterations** with the knowledge layer
- Validated on RIOHTRACK full-scale field data (5 semi-rigid test sections, mean D₀ error: 4.58%)

---

## Repository Structure

```
.
├── backcalculation/          # Core backcalculation framework
│   ├── BackcalculationPPO.m          # PPO-based optimization engine
│   ├── callLLMAPI.m                  # Unified LLM API interface (DeepSeek + Ollama)
│   ├── initialModulusGenerator.m     # LLM-based initial modulus estimation
│   ├── llmSelectBestSolution.m       # Three-layer knowledge-grounded scoring
│   ├── pdeInterface.m                # PDE forward modeling interface
│   ├── runBackcalculation.m          # Main entry point
│   └── verifyLLMOutput.m             # LLM output validation & fallback
│
├── ablation/                 # Ablation study scripts
│   ├── runAblationStudy_v3.m         # 9-variant ablation framework
│   ├── runAblationStudy_v2_4.m       # Earlier ablation version
│   └── resumeAndFinishAnalysis.m     # Checkpoint resume utility
│
├── knowledge_base/           # Specification-grounded knowledge layer
│   ├── knowledge_base.jsonl          # 27 structured knowledge fragments
│   ├── extraction_guide.md           # Guide for extracting specification knowledge
│   └── rag_service/                  # Retrieval-Augmented Generation service
│       ├── rag_server.py             # FastAPI + ChromaDB retrieval server
│       ├── callRAGService.m          # MATLAB ↔ RAG communication
│       └── requirements.txt          # Python dependencies
│
├── core/                     # Forward modeling
│   └── roadPDEModelingABAQUSCalibrated.m  # Axisymmetric FEM with calibration
│
├── data/                     # Test case datasets
│   ├── flexible_structure.csv        # 12 ABAQUS synthetic flexible cases
│   ├── ring_road_test_data_selected.csv   # RIOHTRACK selected sections
│   ├── multi_load_validation_data.csv     # Multi-load verification data
│   └── RIOHTRACK_structure_params.csv     # Structural configurations
│
├── utils/                    # Utility functions
│   ├── loadTestCases.m               # Test case loader
│   ├── runTestCases.m                # Batch test runner
│   ├── backcalculationUtils.m        # Common backcalculation utilities
│   └── extractMultiPositionDeflections.m  # FWD data extraction
│
├── tests/                    # Validation & sensitivity analysis
│   ├── runSensitivityAnalysis_v3.m   # Layer sensitivity & cross-validation
│   ├── runMultiLoadValidation.m      # Multi-load verification
│   └── analyzeABAQUSResults.m        # Result analysis
│
├── config_backcalculation.json       # System configuration (API keys, PPO params)
├── loadBackcalculationConfig.m       # Configuration loader
└── LLM_Prompt设计说明.md             # Prompt design documentation (Chinese)
```

---

## Quick Start

### Prerequisites

- **MATLAB R2024b** or later (with Parallel Computing Toolbox recommended)
- **Python 3.10+** (for RAG knowledge retrieval service)
- **Ollama** (optional, for local LLM deployment)

### Installation

```bash
# 1. Clone the repository
git clone https://github.com/D70905/iLLM-PMB-pavement-modulus-backcalculation.git
cd iLLM-PMB-pavement-modulus-backcalculation

# 2. Install Python dependencies for knowledge retrieval
cd knowledge_base/rag_service
pip install -r requirements.txt

# 3. Pull embedding model for knowledge retrieval (if using Ollama)
ollama pull bge-m3

# 4. Pull LLM for local inference (optional)
ollama pull qwen2.5:7b
```

### Configuration

1. Edit `config_backcalculation.json`:
   - Set `deepseek.api_key` to your DeepSeek API key (or switch to Ollama via `llm_guidance.model: "ollama"`)
   - Adjust `ppo_backcalculation.max_episodes` and `backcalculation.convergence_threshold` as needed

2. Ensure Python RAG service dependencies are installed (`knowledge_base/rag_service/requirements.txt`)

### Running

```matlab
% 1. Start the RAG knowledge retrieval service (terminal)
cd knowledge_base/rag_service
python rag_server.py

% 2. Run a single backcalculation (MATLAB)
cd /path/to/iLLM-PMB
results = runBackcalculation();

% 3. Run ablation study (MATLAB)
results = runAblationStudy_v3([1, 4, 6]);  % specific variants
results = runAblationStudy_v3(1:9);         % all variants

% 4. Run sensitivity analysis (MATLAB)
runSensitivityAnalysis_v3();
```

### Main Ablation Variants

| Variant | Description | Key Switch |
|---------|-------------|------------|
| V1 | LLM-PPO Full | All LLM nodes enabled |
| V4 | PPO-Constraint | No LLM, with physical constraints |
| V6 | Pure PPO | No LLM, no constraints |
| V8 | LLM-PPO + Explicit Knowledge | Three-layer knowledge architecture |
| V9 | LLM-PPO w/o Explicit Knowledge | Old hard-coded prompt (control) |

See `runAblationStudy_v3.m` for the complete variant definitions (V1–V9).

---

## Knowledge Layer Architecture

The specification-grounded knowledge layer consists of three tiers:

```
┌─────────────────────────────────────────────┐
│  Layer 3: LLM Plausibility Adjudication      │
│  • Scores candidates across 4 dimensions     │
│  • Outputs provenance citations              │
│  • Fallback to min-D₀-error if LLM fails     │
├─────────────────────────────────────────────┤
│  Layer 2: RAG Contextual Guidance            │
│  • ChromaDB + BGE-M3 embedding (1024-dim)    │
│  • Dynamic retrieval by pavement type/temp   │
│  • Returns top-k fragments with provenance   │
├─────────────────────────────────────────────┤
│  Layer 1: Hard Physical Boundaries           │
│  • Static injection from JTG D50/ASTM/AASHTO │
│  • Layer stiffness gradients, modulus ranges │
│  • FWD-to-laboratory modulus conversion      │
└─────────────────────────────────────────────┘
```

The knowledge corpus (`knowledge_base/knowledge_base.jsonl`) contains **27 structured fragments** sourced from:

| Source | Type | Fragments |
|--------|------|-----------|
| JTG D50-2017 | Chinese pavement design standard | 10 |
| ASTM D5858-96(2025) | FWD backcalculation standard | 7 |
| AASHTO MEPDG (2008) | Mechanistic-empirical design guide | 3 |
| JTG 3430-2019 | Highway soil testing standard | 2 |
| JTGT F20-2015 | Pavement base construction guidelines | 1 |

---

## Citation

If you use this code or the iLLM-PMB framework in your research, please cite:

```bibtex
@article{xie2026illmpmb,
  title={iLLM-PMB: Specification-Grounded LLM-PPO Framework for FWD-Based Pavement Modulus Backcalculation},
  author={Xie, Jingyi and Wu, Difei and Yang, Ruikang and Sun, Lijun and Hernando, David and Ranyal, Eshta and Tebaldi, Gabriele and Yan, Yu},
  journal={Under Review},
  year={2026}
}
```

---

## License

This project is licensed under the MIT License.

---

## Contact

- **Corresponding Author**: Yu Yan (yyan@tongji.edu.cn)
- **Institution**: The Key Laboratory of Road and Traffic Engineering, Ministry of Education, Tongji University, Shanghai, China
