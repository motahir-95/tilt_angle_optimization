This project calculates the **optimal tilt angle (β)** for solar panels using multiple radiation models.

---

## 🚀 Features

- 8 diffuse radiation models:
  - Liu-Jordan
  - Badescu
  - Klucher
  - Perez
  - Hay-Davies
  - HDKR
  - Koronakis
  - Temps-Coulson

- Supports:
  - Yearly optimization
  - Monthly optimization
  - Seasonal optimization
  - Multi-location comparison (4 locations)

---

## 📂 Project Structure
tilt-angle-optimization/
│
├── src/
│ └── tilt_optimization_4locations_allinone.m
│
├── data/
├── outputs/
└── README.md

---

## ▶️ How to Run

1. Open MATLAB
2. Run:
```matlab
tilt_optimization_4locations_allinone
3.Select 4 input files
4.Enter location info when prompted


## Inputs
Each dataset must include:

time
ghi
dhi
dni

## Outputs

Excel file with:
Yearly optimum tilt
Monthly optimum tilt
Seasonal optimum tilt
Model comparisons
PNG plots:
Energy comparisons
Performance graphs


## Author: Mohammed Eltahir
