%% tilt_optimization_4locations_allinone.m
% Single script for:
% 1) Optimum tilt (Yearly/Monthly/Seasonal) for each diffuse model & each of 4 locations
% 2) Perez optimum angles become default per location
% 3) Compare energy (Perez) using: yearly-opt vs latitude, monthly-opt vs latitude, seasonal-opt vs latitude
% 4) Compute energy gains (kWh/m^2 and %) for all comparisons
% 5) Export ONE Excel file + save all plots as PNG (Turkish labels)
%
% INPUTS:
% - Choose e xactly 4 CSV/XLSX files
% - Each file must have columns (case-insensitive): time, ghi, dhi, dni
% - You only input Lat/Lon/Elev for each location
%
% ROBUSTNESS UPDATES (per your request):
% - Nighttime (and very low sun) capped: GHI/DHI/DNI set to 0 when cos(zen) <= sunThresh
% - Perez NaN handling: any NaN/Inf outputs from Perez set to 0
% - Extra physical sanity checks: DHI <= GHI, clamp negatives, remove NaNs
%
% Seasons: DJF (Kis), MAM (Ilkbahar), JJA (Yaz), SON (Sonbahar)

clear; clc; close all;

%% ================= USER SETTINGS =================
surfaceAz_deg = 180;           % Panel azimutu (deg): 180=Guney
albedo        = 0.20;          % Albedo
betaGrid_deg  = (0:1:90)';     % Eğim taraması (deg)
sunThresh     = 0.01;          % cos(zen) > sunThresh => gunduz (night capped)
epsI          = 1e-3;          % gunduz 0 irradiance -> kucuk deger (W/m^2) to avoid ratios/0

modelList = { ...
    'LiuJordan', ...
    'Badescu', ...
    'Klucher', ...
    'Perez', ...
    'HayDavies', ...
    'HDKR', ...
    'Koronakis', ...
    'TempsCoulson' ...
};

ayTR   = ["Oca","Sub","Mar","Nis","May","Haz","Tem","Agu","Eyl","Eki","Kas","Ara"];
mevTR  = ["Kis (DJF)","Ilkbahar (MAM)","Yaz (JJA)","Sonbahar (SON)"];

Nm = numel(modelList);
Nb = numel(betaGrid_deg);

% Outputs
outXlsx = fullfile(pwd, 'TiltOptimization_4Locations_AllResults.xlsx');
outDir  = fullfile(pwd, 'Grafikler_PNG');
if exist(outXlsx,'file')==2, delete(outXlsx); end
if ~exist(outDir,'dir'), mkdir(outDir); end

%% ================= SELECT 4 FILES =================
[fileNames, filePath] = uigetfile({'*.csv;*.xlsx','Veri Dosyalari (*.csv, *.xlsx)'}, ...
    '4 lokasyonun veri dosyalarini sec (MultiSelect)', 'MultiSelect','on');
assert(~isequal(fileNames,0), 'Dosya secilmedi.');
if ischar(fileNames), fileNames = {fileNames}; end
assert(numel(fileNames)==4, 'Lutfen tam olarak 4 dosya secin. (Secili: %d)', numel(fileNames));

nLoc = 4;
locFiles = strings(nLoc,1);
locNames = strings(nLoc,1);
for i=1:nLoc
    locFiles(i) = string(fullfile(filePath, fileNames{i}));
    [~, nm, ~] = fileparts(locFiles(i));
    locNames(i) = string(nm);
end

%% ================= INPUT ONLY LOCATION DATA =================
prompt = {};
defans = {};
for i=1:nLoc
    prompt{end+1} = sprintf('%s - Enlem (deg)',  locNames(i));
    prompt{end+1} = sprintf('%s - Boylam (deg)', locNames(i));
    prompt{end+1} = sprintf('%s - Yukseklik (m)',locNames(i));
    defans{end+1} = '0';
    defans{end+1} = '0';
    defans{end+1} = '0';
end
answ = inputdlg(prompt, 'Lokasyon Koordinatlari (Sadece Lat/Lon/Elev)', 1, defans);
assert(~isempty(answ), 'Lokasyon girisi iptal edildi.');

Lat  = zeros(nLoc,1);
Lon  = zeros(nLoc,1);
Elev = zeros(nLoc,1);
k=1;
for i=1:nLoc
    Lat(i)  = str2double(answ{k}); k=k+1;
    Lon(i)  = str2double(answ{k}); k=k+1;
    Elev(i) = str2double(answ{k}); k=k+1;
end
latTilt_deg = abs(Lat);

%% ================= PRE-ALLOC TABLES =================
OptTilt_Yillik  = table();
OptTilt_Aylik   = table();
OptTilt_Mevsim  = table();

Perez_DefaultAngles = table();

Perez_Yillik_Karsilastirma  = table();
Perez_Aylik_Karsilastirma   = table();
Perez_Mevsim_Karsilastirma  = table();

% ---- NEW: energy + gain for ALL models (vs latitude) ----
Model_Yillik_Karsilastirma  = table();
Model_Aylik_Karsilastirma   = table();
Model_Mevsim_Karsilastirma  = table();

% ---- NEW: statistical deviations (monthly) using Perez as benchmark ----
Stats_Aylik_Hatalar_PerezBenchmark = table();


Summary_AnnualGains = table();

%% ================= MAIN LOOP OVER LOCATIONS =================
for L = 1:nLoc
    fprintf('\n=== Lokasyon: %s ===\n', locNames(L));

    % ---------- Read file ----------
    [Time, GHI, DHI, DNI] = read_tmy_table(locFiles(L));

    % ---------- Compute dt (hours) for correct energy ----------
    dt_h = hours([diff(Time); Time(end)-Time(end-1)]);
    if any(dt_h<=0 | isnan(dt_h))
        dt_h(dt_h<=0 | isnan(dt_h)) = median(dt_h(dt_h>0 & ~isnan(dt_h)));
    end
    dt_h = dt_h(:);

    % ---------- Solar position + extraterrestrial ----------
    [zen_deg, saz_deg, E0_Wm2] = solar_position_and_extrarad_pvlib(Time, Lat(L), Lon(L), Elev(L));

    % ---------- Nighttime cap (requested) ----------
    sunUp = cosd(zen_deg) > sunThresh;

    % Basic cleaning
    GHI = max(GHI,0); DHI = max(DHI,0); DNI = max(DNI,0);
    GHI(isnan(GHI))=0; DHI(isnan(DHI))=0; DNI(isnan(DNI))=0;

    % Physical sanity: diffuse cannot exceed global
    DHI = min(DHI, GHI);

    % NIGHT: force to zero
    GHI(~sunUp)=0;
    DHI(~sunUp)=0;
    DNI(~sunUp)=0;

    % DAY: avoid ratios/0 in some models
    GHI(sunUp & GHI==0) = epsI;
    DHI(sunUp & DHI==0) = epsI;
    DNI(sunUp & DNI==0) = epsI;

    % ---------- Geometry ----------
    cosZ = cosd(zen_deg);
    sinZ = sind(zen_deg);
    cosZ_safe = max(cosZ, 1e-6);

    beta = betaGrid_deg(:)';  % 1 x Nb
    cb   = cosd(beta);
    sb   = sind(beta);

    cosInc = cosZ.*cb + (sinZ.*sb).*cosd(saz_deg - surfaceAz_deg); % Nt x Nb
    cosInc = max(cosInc,0);

    Eb_tilt = DNI .* cosInc;                    % Nt x Nb
    Eg_tilt = (GHI .* albedo) .* (1 - cb) / 2;  % Nt x Nb

    % ---------- Common indices ----------
    Kt = (GHI ./ (E0_Wm2 .* cosZ_safe));
    Kt = min(max(Kt,0), 2);

    AI = (DNI ./ max(E0_Wm2,1e-6));
    AI = min(max(AI,0), 1.5);

    Fd_iso = (1 + cb)/2;     % 1 x Nb
    BHI = DNI .* cosZ;       % Nt x 1

    monVec = month(Time);              % 1..12
    seaID  = season_id_DJF_MAM_JJA_SON(monVec); % 1..4

    % ---------- Compute Epoa for each model ----------
    ResultsLoc = struct(); % store Epoa per model (Nt x Nb)

    for m = 1:Nm
        model = modelList{m};

        Ed_tilt = diffuse_on_tilt_allbetas( ...
            model, betaGrid_deg, zen_deg, saz_deg, surfaceAz_deg, ...
            GHI, DHI, DNI, E0_Wm2, Kt, AI, Fd_iso, cosInc, cosZ_safe, BHI);

        Epoa = Eb_tilt + Ed_tilt + Eg_tilt;
        Epoa = max(Epoa,0);

        % Safety: remove NaN/Inf (important if Perez returns NaNs)
        Epoa(~isfinite(Epoa)) = 0;

        ResultsLoc.(model).Epoa_all = Epoa;
    end

    % ---------- 1) OPTIMUM ANGLES by EACH MODEL ----------
    betaOpt_year = nan(Nm,1);
    betaOpt_mon  = nan(Nm,12);
    betaOpt_sea  = nan(Nm,4);

    for m = 1:Nm
        model = modelList{m};
        Epoa  = ResultsLoc.(model).Epoa_all;

        % YEARLY optimum
        H = sum(Epoa .* dt_h, 1, 'omitnan');     % Wh/m^2 across time
        [~, idx] = max(H);
        betaOpt_year(m) = betaGrid_deg(idx);

        % MONTHLY optimum
        for mo=1:12
            mask = (monVec==mo);
            Hm = sum(Epoa(mask,:) .* dt_h(mask), 1, 'omitnan');
            [~, idm] = max(Hm);
            betaOpt_mon(m,mo) = betaGrid_deg(idm);
        end

        % SEASONAL optimum
        for s=1:4
            mask = (seaID==s);
            Hs = sum(Epoa(mask,:) .* dt_h(mask), 1, 'omitnan');
            [~, ids] = max(Hs);
            betaOpt_sea(m,s) = betaGrid_deg(ids);
        end
    end

    % ---------- Save optimum-angle tables (ALL models) ----------
    Tyear = table( ...
        repmat(locNames(L),Nm,1), repmat(Lat(L),Nm,1), repmat(Lon(L),Nm,1), repmat(Elev(L),Nm,1), ...
        string(modelList(:)), betaOpt_year, ...
        'VariableNames', {'Bolge','Enlem_deg','Boylam_deg','Yukseklik_m','Model','BetaOpt_Yillik_deg'});
    OptTilt_Yillik = [OptTilt_Yillik; Tyear];

    Tmon = table(repmat(locNames(L),Nm,1), string(modelList(:)), ...
        betaOpt_mon(:,1), betaOpt_mon(:,2), betaOpt_mon(:,3), betaOpt_mon(:,4), betaOpt_mon(:,5), betaOpt_mon(:,6), ...
        betaOpt_mon(:,7), betaOpt_mon(:,8), betaOpt_mon(:,9), betaOpt_mon(:,10), betaOpt_mon(:,11), betaOpt_mon(:,12), ...
        'VariableNames', {'Bolge','Model','Oca','Sub','Mar','Nis','May','Haz','Tem','Agu','Eyl','Eki','Kas','Ara'});
    OptTilt_Aylik = [OptTilt_Aylik; Tmon];

    Tsea = table(repmat(locNames(L),Nm,1), string(modelList(:)), ...
        betaOpt_sea(:,1), betaOpt_sea(:,2), betaOpt_sea(:,3), betaOpt_sea(:,4), ...
        'VariableNames', {'Bolge','Model','Kis_DJF','Ilkbahar_MAM','Yaz_JJA','Sonbahar_SON'});
    OptTilt_Mevsim = [OptTilt_Mevsim; Tsea];

    % ---------- 2) Perez optimum angles are DEFAULT per location ----------
    iPerez = find(strcmp(modelList,'Perez'),1);
    assert(~isempty(iPerez),'Perez modeli modelList icinde yok.');

    betaY_perez = betaOpt_year(iPerez);
    betaM_perez = betaOpt_mon(iPerez,:);   % 1x12
    betaS_perez = betaOpt_sea(iPerez,:);   % 1x4

    [~, idxYopt] = min(abs(betaGrid_deg - betaY_perez));
    idxMopt = zeros(12,1);
    for mo=1:12, [~, idxMopt(mo)] = min(abs(betaGrid_deg - betaM_perez(mo))); end
    idxSopt = zeros(4,1);
    for s=1:4,  [~, idxSopt(s)]  = min(abs(betaGrid_deg - betaS_perez(s)));  end

    betaLat = latTilt_deg(L);
    [~, idxLat] = min(abs(betaGrid_deg - betaLat));
    betaLat_used = betaGrid_deg(idxLat);

    % Store Perez default angles
    Perez_DefaultAngles = [Perez_DefaultAngles; ...
        table(locNames(L), Lat(L), betaLat_used, betaY_perez, ...
        betaM_perez(1),betaM_perez(2),betaM_perez(3),betaM_perez(4),betaM_perez(5),betaM_perez(6), ...
        betaM_perez(7),betaM_perez(8),betaM_perez(9),betaM_perez(10),betaM_perez(11),betaM_perez(12), ...
        betaS_perez(1),betaS_perez(2),betaS_perez(3),betaS_perez(4), ...
        'VariableNames', {'Bolge','Enlem_deg','Beta_Enlem_deg','Perez_BetaOpt_Yillik_deg', ...
        'Perez_Oca','Perez_Sub','Perez_Mar','Perez_Nis','Perez_May','Perez_Haz','Perez_Tem','Perez_Agu','Perez_Eyl','Perez_Eki','Perez_Kas','Perez_Ara', ...
        'Perez_Kis_DJF','Perez_Ilkbahar_MAM','Perez_Yaz_JJA','Perez_Sonbahar_SON'})];

    
    % ---------- 3A) COMPARISONS (ALL MODELS) vs Latitude + Stats vs Perez ----------
    % Compute Perez benchmark MONTHLY energy at its own monthly-optimum (benchmark vector y)
    EpoaPerez = ResultsLoc.Perez.Epoa_all; % Nt x Nb
    EpoaPerez(~isfinite(EpoaPerez)) = 0;

    % Perez monthly-optimum indices already built (idxMopt)
    E_mon_opt_perez = zeros(12,1);
    for mo=1:12
        mask = (monVec==mo);
        E_mon_opt_perez(mo) = sum(EpoaPerez(mask, idxMopt(mo)).*dt_h(mask),'omitnan')/1000; % kWh/m^2
    end

    for m = 1:Nm
        model = modelList{m};
        Epoa  = ResultsLoc.(model).Epoa_all; % Nt x Nb

        % Indices for THIS model optimums
        [~, idxY] = min(abs(betaGrid_deg - betaOpt_year(m)));

        idxM = zeros(12,1);
        for mo=1:12
            [~, idxM(mo)] = min(abs(betaGrid_deg - betaOpt_mon(m,mo)));
        end

        idxS = zeros(4,1);
        for s=1:4
            [~, idxS(s)] = min(abs(betaGrid_deg - betaOpt_sea(m,s)));
        end

        % ===== YEARLY (opt vs latitude) =====
        E_year_opt_m = sum(Epoa(:,idxY).*dt_h,'omitnan')/1000;
        E_year_lat_m = sum(Epoa(:,idxLat).*dt_h,'omitnan')/1000;
        Gain_year_kWh_m = E_year_opt_m - E_year_lat_m;
        Gain_year_pct_m = 100*Gain_year_kWh_m / max(E_year_lat_m,1e-9);

        Model_Yillik_Karsilastirma = [Model_Yillik_Karsilastirma; ...
            table(locNames(L), string(model), Lat(L), betaLat_used, betaOpt_year(m), ...
            E_year_opt_m, E_year_lat_m, Gain_year_kWh_m, Gain_year_pct_m, ...
            'VariableNames', {'Bolge','Model','Enlem_deg','Beta_Enlem_deg','BetaOpt_Yillik_deg', ...
                              'YillikEnerji_Opt_kWhm2','YillikEnerji_Enlem_kWhm2','KazancKayip_kWhm2','KazancKayip_pct'})];

        % ===== MONTHLY (opt vs latitude) =====
        E_mon_opt_m = zeros(12,1);
        E_mon_lat_m = zeros(12,1);
        for mo=1:12
            mask = (monVec==mo);
            E_mon_opt_m(mo) = sum(Epoa(mask, idxM(mo)).*dt_h(mask),'omitnan')/1000;
            E_mon_lat_m(mo) = sum(Epoa(mask, idxLat).*dt_h(mask),'omitnan')/1000;
        end
        Gain_mon_kWh_m = E_mon_opt_m - E_mon_lat_m;
        Gain_mon_pct_m = 100*Gain_mon_kWh_m ./ max(E_mon_lat_m,1e-9);

        Model_Aylik_Karsilastirma = [Model_Aylik_Karsilastirma; ...
            table(repmat(locNames(L),12,1), repmat(string(model),12,1), ayTR(:), repmat(Lat(L),12,1), ...
            repmat(betaLat_used,12,1), betaOpt_mon(m,:)', ...
            E_mon_opt_m, E_mon_lat_m, Gain_mon_kWh_m, Gain_mon_pct_m, ...
            'VariableNames', {'Bolge','Model','Ay','Enlem_deg','Beta_Enlem_deg','BetaOpt_Ay_deg', ...
                              'AylikEnerji_Opt_kWhm2','AylikEnerji_Enlem_kWhm2','KazancKayip_kWhm2','KazancKayip_pct'})];

        % ===== SEASONAL (opt vs latitude) =====
        E_sea_opt_m = zeros(4,1);
        E_sea_lat_m = zeros(4,1);
        for s=1:4
            mask = (seaID==s);
            E_sea_opt_m(s) = sum(Epoa(mask, idxS(s)).*dt_h(mask),'omitnan')/1000;
            E_sea_lat_m(s) = sum(Epoa(mask, idxLat).*dt_h(mask),'omitnan')/1000;
        end
        Gain_sea_kWh_m = E_sea_opt_m - E_sea_lat_m;
        Gain_sea_pct_m = 100*Gain_sea_kWh_m ./ max(E_sea_lat_m,1e-9);

        Model_Mevsim_Karsilastirma = [Model_Mevsim_Karsilastirma; ...
            table(repmat(locNames(L),4,1), repmat(string(model),4,1), mevTR(:), repmat(Lat(L),4,1), ...
            repmat(betaLat_used,4,1), betaOpt_sea(m,:)', ...
            E_sea_opt_m, E_sea_lat_m, Gain_sea_kWh_m, Gain_sea_pct_m, ...
            'VariableNames', {'Bolge','Model','Mevsim','Enlem_deg','Beta_Enlem_deg','BetaOpt_Mevsim_deg', ...
                              'MevsimEnerji_Opt_kWhm2','MevsimEnerji_Enlem_kWhm2','KazancKayip_kWhm2','KazancKayip_pct'})];

        % ===== STATS (monthly) vs Perez benchmark =====
        % Benchmark: Perez monthly optimum energies (E_mon_opt_perez).
        % Compare model monthly optimum energies (E_mon_opt_m) to benchmark.
        e = E_mon_opt_m - E_mon_opt_perez;
        MBE  = mean(e,'omitnan');
        RMSE = sqrt(mean(e.^2,'omitnan'));
        MAE  = mean(abs(e),'omitnan');
        MAPE = 100*mean(abs(e)./max(E_mon_opt_perez,1e-9),'omitnan');

        % R^2
        y = E_mon_opt_perez;
        x = E_mon_opt_m;
        ybar = mean(y,'omitnan');
        SSres = sum((y-x).^2,'omitnan');
        SStot = sum((y-ybar).^2,'omitnan');
        R2 = 1 - SSres/max(SStot,1e-12);

        Stats_Aylik_Hatalar_PerezBenchmark = [Stats_Aylik_Hatalar_PerezBenchmark; ...
            table(locNames(L), string(model), MBE, RMSE, MAE, MAPE, R2, ...
            'VariableNames', {'Bolge','Model','MBE_kWhm2','RMSE_kWhm2','MAE_kWhm2','MAPE_pct','R2'})];
    end


% ---------- 3) COMPARISONS (Perez energy) vs Latitude ----------
    EpoaPerez = ResultsLoc.Perez.Epoa_all; % Nt x Nb
    EpoaPerez(~isfinite(EpoaPerez)) = 0;  % extra safety

    % ===== A) Yearly-opt vs Latitude (Annual energy) =====
    E_year_opt = sum(EpoaPerez(:,idxYopt).*dt_h,'omitnan')/1000;
    E_year_lat = sum(EpoaPerez(:,idxLat).*dt_h,'omitnan')/1000;
    Gain_year_kWh = E_year_opt - E_year_lat;
    Gain_year_pct = 100*Gain_year_kWh / max(E_year_lat,1e-9);

    Perez_Yillik_Karsilastirma = [Perez_Yillik_Karsilastirma; ...
        table(locNames(L), Lat(L), betaLat_used, betaY_perez, ...
        E_year_opt, E_year_lat, Gain_year_kWh, Gain_year_pct, ...
        'VariableNames', {'Bolge','Enlem_deg','Beta_Enlem_deg','Perez_BetaOpt_Yillik_deg', ...
                          'YillikEnerji_Opt_kWhm2','YillikEnerji_Enlem_kWhm2','KazancKayip_kWhm2','KazancKayip_pct'})];

    % ===== B) Monthly-opt vs Latitude (Monthly energies) =====
    E_mon_opt = zeros(12,1);
    E_mon_lat = zeros(12,1);
    for mo=1:12
        mask = (monVec==mo);
        E_mon_opt(mo) = sum(EpoaPerez(mask, idxMopt(mo)).*dt_h(mask),'omitnan')/1000;
        E_mon_lat(mo) = sum(EpoaPerez(mask, idxLat).*dt_h(mask),'omitnan')/1000;
    end
    Gain_mon_kWh = E_mon_opt - E_mon_lat;
    Gain_mon_pct = 100*Gain_mon_kWh ./ max(E_mon_lat,1e-9);

    Perez_Aylik_Karsilastirma = [Perez_Aylik_Karsilastirma; ...
        table(repmat(locNames(L),12,1), ayTR(:), repmat(Lat(L),12,1), repmat(betaLat_used,12,1), betaM_perez(:), ...
        E_mon_opt, E_mon_lat, Gain_mon_kWh, Gain_mon_pct, ...
        'VariableNames', {'Bolge','Ay','Enlem_deg','Beta_Enlem_deg','Perez_BetaOpt_Ay_deg', ...
                          'AylikEnerji_Opt_kWhm2','AylikEnerji_Enlem_kWhm2','KazancKayip_kWhm2','KazancKayip_pct'})];

    % ===== C) Seasonal-opt vs Latitude (Seasonal energies) =====
    E_sea_opt = zeros(4,1);
    E_sea_lat = zeros(4,1);
    for s=1:4
        mask = (seaID==s);
        E_sea_opt(s) = sum(EpoaPerez(mask, idxSopt(s)).*dt_h(mask),'omitnan')/1000;
        E_sea_lat(s) = sum(EpoaPerez(mask, idxLat).*dt_h(mask),'omitnan')/1000;
    end
    Gain_sea_kWh = E_sea_opt - E_sea_lat;
    Gain_sea_pct = 100*Gain_sea_kWh ./ max(E_sea_lat,1e-9);

    Perez_Mevsim_Karsilastirma = [Perez_Mevsim_Karsilastirma; ...
        table(repmat(locNames(L),4,1), mevTR(:), repmat(Lat(L),4,1), repmat(betaLat_used,4,1), betaS_perez(:), ...
        E_sea_opt, E_sea_lat, Gain_sea_kWh, Gain_sea_pct, ...
        'VariableNames', {'Bolge','Mevsim','Enlem_deg','Beta_Enlem_deg','Perez_BetaOpt_Mevsim_deg', ...
                          'MevsimEnerji_Opt_kWhm2','MevsimEnerji_Enlem_kWhm2','KazancKayip_kWhm2','KazancKayip_pct'})];

    % Summary
    Summary_AnnualGains = [Summary_AnnualGains; ...
        table(locNames(L), Gain_year_kWh, Gain_year_pct, ...
        'VariableNames', {'Bolge','YillikKazancKayip_kWhm2','YillikKazancKayip_pct'})];

    %% ================= PLOTS (Turkish) - SAVE PNG =================
    % 1) Yearly energy
    fig = figure('Visible','off');
    bar(categorical(["Optimum (Perez-Yillik)","Enlem"]), [E_year_opt, E_year_lat]);
    grid on; ylabel('Yillik Enerji (kWh/m^2)');
    title("Yillik Enerji Karsilastirmasi - " + locNames(L));
    saveas(fig, fullfile(outDir, "YillikEnerji_" + locNames(L) + ".png"));
    close(fig);

    % 2) Yearly gain
    fig = figure('Visible','off');
    bar(categorical(locNames(L)), Gain_year_kWh);
    grid on; ylabel('Kazanc/Kayip (kWh/m^2)');
    title("Yillik Kazanc/Kayip (Opt - Enlem) - " + locNames(L));
    saveas(fig, fullfile(outDir, "YillikKazanc_" + locNames(L) + ".png"));
    close(fig);

    % 3) Monthly energy
    fig = figure('Visible','off');
    plot(1:12, E_mon_opt,'-o'); hold on; grid on;
    plot(1:12, E_mon_lat,'-o');
    xticks(1:12); xticklabels(ayTR);
    xlabel('Ay'); ylabel('Aylik Enerji (kWh/m^2)');
    title("Aylik Enerji (Perez-Aylik Opt vs Enlem) - " + locNames(L));
    legend('Aylik Optimum','Enlem','Location','best');
    saveas(fig, fullfile(outDir, "AylikEnerji_" + locNames(L) + ".png"));
    close(fig);

    % 4) Monthly gain
    fig = figure('Visible','off');
    bar(categorical(ayTR), Gain_mon_kWh);
    grid on; ylabel('Kazanc/Kayip (kWh/m^2)');
    title("Aylik Kazanc/Kayip (Opt - Enlem) - " + locNames(L));
    saveas(fig, fullfile(outDir, "AylikKazanc_" + locNames(L) + ".png"));
    close(fig);

    % 5) Seasonal energy
    fig = figure('Visible','off');
    bar(categorical(mevTR), [E_sea_opt, E_sea_lat]);
    grid on; ylabel('Mevsimsel Enerji (kWh/m^2)');
    title("Mevsimsel Enerji (Perez-Mevsim Opt vs Enlem) - " + locNames(L));
    legend('Mevsim Optimum','Enlem','Location','best');
    saveas(fig, fullfile(outDir, "MevsimEnerji_" + locNames(L) + ".png"));
    close(fig);

    % 6) Seasonal gain
    fig = figure('Visible','off');
    bar(categorical(mevTR), Gain_sea_kWh);
    grid on; ylabel('Kazanc/Kayip (kWh/m^2)');
    title("Mevsimsel Kazanc/Kayip (Opt - Enlem) - " + locNames(L));
    saveas(fig, fullfile(outDir, "MevsimKazanc_" + locNames(L) + ".png"));
    close(fig);

    % 7) Yearly optimum tilt across all models
    fig = figure('Visible','off');
    bar(categorical(string(modelList)), betaOpt_year);
    grid on; ylabel('Optimum Eğim \beta_{opt} (deg)');
    title("Yillik Optimum Eğim (Tum Modeller) - " + locNames(L));
    saveas(fig, fullfile(outDir, "BetaOptYillik_TumModeller_" + locNames(L) + ".png"));
    close(fig);
end

%% ================= GLOBAL PLOT: annual gain across locations =================
fig = figure('Visible','off');
bar(categorical(Summary_AnnualGains.Bolge), Summary_AnnualGains.YillikKazancKayip_kWhm2);
grid on; ylabel('Yillik Kazanc/Kayip (kWh/m^2)');
title('Yillik Kazanc/Kayip (Perez Yillik Opt vs Enlem) - Tum Lokasyonlar');
saveas(fig, fullfile(outDir, "TumLokasyonlar_YillikKazanc.png"));
close(fig);

%% ================= WRITE ONE EXCEL FILE =================
writetable(OptTilt_Yillik,         outXlsx, 'Sheet','OptTilt_Yillik');
writetable(OptTilt_Aylik,          outXlsx, 'Sheet','OptTilt_Aylik');
writetable(OptTilt_Mevsim,         outXlsx, 'Sheet','OptTilt_Mevsim');

writetable(Perez_DefaultAngles,    outXlsx, 'Sheet','Perez_DefaultAngles');

writetable(Perez_Yillik_Karsilastirma, outXlsx, 'Sheet','Perez_Yillik_vs_Enlem');
writetable(Perez_Aylik_Karsilastirma,  outXlsx, 'Sheet','Perez_Aylik_vs_Enlem');
writetable(Perez_Mevsim_Karsilastirma, outXlsx, 'Sheet','Perez_Mevsim_vs_Enlem');

% ---- NEW: ALL models energy + gain (vs latitude) ----
writetable(Model_Yillik_Karsilastirma, outXlsx, 'Sheet','TumModeller_Yillik_vs_Enlem');
writetable(Model_Aylik_Karsilastirma,  outXlsx, 'Sheet','TumModeller_Aylik_vs_Enlem');
writetable(Model_Mevsim_Karsilastirma, outXlsx, 'Sheet','TumModeller_Mevsim_vs_Enlem');

% ---- NEW: Stats (monthly) using Perez benchmark ----
writetable(Stats_Aylik_Hatalar_PerezBenchmark, outXlsx, 'Sheet','Istatistik_Hatalar_vs_Perez');


writetable(Summary_AnnualGains, outXlsx, 'Sheet','Ozet_YillikKazanc');

disp("Excel kaydedildi: " + outXlsx);
disp("Grafikler klasoru: " + outDir);

%% ========================================================================
%% ============================== HELPERS ================================
%% ========================================================================

function [Time, GHI, DHI, DNI] = read_tmy_table(filePath)
T = readtable(filePath);
T.Properties.VariableNames = lower(string(T.Properties.VariableNames));
req = ["time","ghi","dhi","dni"];
assert(all(ismember(req, T.Properties.VariableNames)), ...
    'Dosya %s icin gerekli sutunlar yok: time, ghi, dhi, dni', filePath);

Time = T.time;
if ~isdatetime(Time)
    try
        Time = datetime(string(Time), 'TimeZone','UTC');
    catch
        Time = datetime(string(Time), 'InputFormat','yyyyMMdd:HHmm', 'TimeZone','UTC');
    end
else
    if isempty(Time.TimeZone), Time.TimeZone = 'UTC'; end
end
Time = Time(:);

GHI = T.ghi(:);
DHI = T.dhi(:);
DNI = T.dni(:);
end

function sid = season_id_DJF_MAM_JJA_SON(monVec)
sid = zeros(size(monVec));
sid(ismember(monVec,[12 1 2])) = 1;
sid(ismember(monVec,[3 4 5]))  = 2;
sid(ismember(monVec,[6 7 8]))  = 3;
sid(ismember(monVec,[9 10 11]))= 4;
end

function [zen_deg, saz_deg, E0_Wm2] = solar_position_and_extrarad_pvlib(Time, Lat, Lon, Elev)
Nt = numel(Time);
zen_deg = nan(Nt,1); saz_deg = nan(Nt,1); E0_Wm2 = nan(Nt,1);

if exist('pvl_extraradiation','file')==2
    doy = day(Time,'dayofyear');
    E0_Wm2 = pvl_extraradiation(doy);
else
    doy = day(Time,'dayofyear');
    g = 2*pi*(doy-1)/365;
    E0_Wm2 = 1367*(1.00011 + 0.034221*cos(g) + 0.00128*sin(g) + 0.000719*cos(2*g) + 0.000077*sin(2*g));
end

try
    if exist('pvl_ephemeris','file')==2
        dn = datenum(Time);
        [SunAz, SunEl, ~, ~] = pvl_ephemeris(dn, Lat, Lon, Elev);
        saz_deg = SunAz(:);
        zen_deg = 90 - SunEl(:);
        return;
    end
catch
end

try
    if exist('pvlib_solarposition','file')==2
        solpos = pvlib_solarposition(Time, Lat, Lon, Elev);
        zen_deg = solpos.zenith(:);
        saz_deg = solpos.azimuth(:);
        return;
    end
catch
end

doy = day(Time,'dayofyear');
fracHour = hour(Time) + minute(Time)/60 + second(Time)/3600;
decl = 23.45*sind(360*(284 + doy)/365);
HRA  = 15*(fracHour - 12);
zen_deg = acosd( sind(Lat).*sind(decl) + cosd(Lat).*cosd(decl).*cosd(HRA) );
az_south = atan2d( sind(HRA), (cosd(HRA).*sind(Lat) - tand(decl).*cosd(Lat)) );
saz_deg = mod(az_south + 180, 360);
end

function Ed_tilt = diffuse_on_tilt_allbetas(model, betaGrid_deg, zen, saz, surfAz, GHI, DHI, DNI, E0, Kt, AI, Fd_iso, cosInc, cosZ, BHI)
beta = betaGrid_deg(:)';   % 1 x Nb

switch lower(model)
    case lower('LiuJordan')
        Ed_tilt = DHI .* Fd_iso;

    case lower('Badescu')
        % Badescu diffuse transposition factor:
        % Rd = (3 + cos(2β)) / 4
        Rd = (3 + cosd(2*beta)) / 4;
        Ed_tilt = DHI .* Rd;

    case lower('Koronakis')
        Fk = (2 + cosd(beta))/3;
        Ed_tilt = DHI .* Fk;

    case lower('Klucher')
        epsG = max(GHI, 1e-6);
        F = 1 - (DHI./epsG).^2;
        F = min(max(F,0),1);
        sinb2 = sind(beta/2);
        term1 = Fd_iso .* (1 + (F * (sinb2.^3)));
        term2 = 1 + (F .* (cosInc.^2) .* (sind(zen).^3));
        Ed_tilt = DHI .* term1 .* term2;

    case lower('HayDavies')
        Rb = cosInc ./ max(cosZ, 1e-6);
        Rb = max(Rb, 0);
        Ed_tilt = DHI .* ( (AI .* Rb) + ((1-AI) .* Fd_iso) );

    case lower('HDKR')
        epsG = max(GHI, 1e-6);
        f = sqrt(max(BHI./epsG, 0));
        Rb = cosInc ./ max(cosZ, 1e-6);
        Rb = max(Rb, 0);
        sinb2 = sind(beta/2);
        base = (AI .* Rb) + ((1-AI).*Fd_iso.*(1 + (f*(sinb2.^3))));
        hb   = 1 + (f .* (cosInc.^2) .* (sind(zen).^3));
        Ed_tilt = DHI .* base .* hb;

    case lower('TempsCoulson')
        sinb2 = sind(beta/2);
        termA = Fd_iso .* (1 + sinb2.^3);
        termB = 1 + (cosInc.^2) .* (sind(zen).^3);
        Ed_tilt = DHI .* termA .* termB;

    case lower('Perez')
        % Perez 1990 (all-sites composite) implementation (no pvlib dependency)
        Ed_tilt = perez1990_diffuse_allbetas(betaGrid_deg, DHI, DNI, zen, E0, cosInc, cosZ);

    otherwise
        error('Unknown model: %s', model);
end

Ed_tilt = max(Ed_tilt, 0);
Ed_tilt(~isfinite(Ed_tilt)) = 0; % critical NaN/Inf cleanup
end


function Ed = perez1990_diffuse_allbetas(betaGrid_deg, DHI, DNI, zen_deg, E0_Wm2, cosInc, cosZ)
% Perez 1990 (all-sites composite) sky diffuse on tilted plane for ALL betas.
% Returns Ed (Nt x Nb) in W/m^2.
%
% Stability features:
% - Uses Kasten-Young airmass (zen clipped)
% - b term uses max(cos(85°),cosZ) per Perez definition
% - Clips negative / non-finite outputs to 0

Nt = numel(zen_deg);
beta = betaGrid_deg(:)';  % 1 x Nb
Nb = numel(beta);

% Perez uses: a = cos(theta) and b = max(cos(85), cosZ)
a = max(0, cosInc);                        % Nt x Nb
b = max(cosd(85), max(cosZ, 1e-6));        % Nt x 1

% Relative airmass
AM = kasten_young_airmass(zen_deg);

% Sky clearness ε
zclip = min(max(zen_deg,0), 89.999);
zrad = deg2rad(zclip);
z3 = zrad.^3;
epsC = ((DHI + DNI) ./ max(1e-6, DHI) + 1.041*z3) ./ (1 + 1.041*z3);

% Sky brightness Δ
delta = DHI .* AM ./ max(1e-6, E0_Wm2);

% Perez 1990 all-sites composite coefficients (8 bins)
edges = [1.000, 1.065, 1.230, 1.500, 1.950, 2.800, 4.500, 6.200, Inf];
C = [...
   -0.008,  0.588, -0.062, -0.060,  0.072, -0.022;...
    0.130,  0.683, -0.151, -0.019,  0.066, -0.029;...
    0.330,  0.487, -0.221,  0.055, -0.064, -0.026;...
    0.568,  0.187, -0.295,  0.109, -0.152, -0.014;...
    0.873, -0.392, -0.362,  0.226, -0.462,  0.001;...
    1.132, -1.237, -0.412,  0.288, -0.823,  0.056;...
    1.060, -1.600, -0.359,  0.264, -1.127,  0.131;...
    0.678, -0.327, -0.250,  0.156, -1.377,  0.251];

% Assign bins
bin = ones(Nt,1);
for k = 1:8
    bin(epsC >= edges(k) & epsC < edges(k+1)) = k;
end

% Compute F1, F2
F1 = zeros(Nt,1);
F2 = zeros(Nt,1);
for k = 1:8
    idxk = (bin == k);
    if any(idxk)
        F11 = C(k,1); F12 = C(k,2); F13 = C(k,3);
        F21 = C(k,4); F22 = C(k,5); F23 = C(k,6);
        F1(idxk) = max(0, F11 + F12.*delta(idxk) + F13.*zen_deg(idxk));
        F2(idxk) =       (F21 + F22.*delta(idxk) + F23.*zen_deg(idxk));
    end
end

% Perez diffuse on tilt
iso = (1 - F1) .* (1 + cosd(beta)) / 2;   % Nt x Nb (implicit expansion)
cir = F1 .* (a ./ b);                     % Nt x Nb
hor = F2 .* sind(beta);                   % Nt x Nb

Ed = DHI .* max(0, iso + cir + hor);
Ed(~isfinite(Ed)) = 0;
Ed = max(0, Ed);
end


function AM = kasten_young_airmass(zen_deg)
z = min(max(zen_deg,0), 89.9);
AM = 1 ./ (cosd(z) + 0.50572*((96.07995 - z).^(-1.6364)));
end
