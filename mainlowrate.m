
%function [ r, Cn2b, timestamps_IMU, WASPloc, timestamps_WASP  ] = main( INSfile, loss_freq, loss_period )
function [  ] = main( INSfile, loss_freq, loss_period )

% main function that runs an INS / WASP Kalman filter integration
% Do a 'clear all' first or sometimes you will get an error
clearvars -except INSfile loss_freq loss_period 
global a v r rpy Cn2b ba bg dr dv fs fsc ws wsc epsilon WASPloc timestamps_IMU...
 timestamps_WASP nS nS_filter front Sk innov actual_ba actual_bg signal_loss_errors...
 ms mn_cal gn_cal Pk

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%   LOADING DATA

% Read imu data stored as Nx13 array of TsGxGyGzAxAyAzTxTyTzMxMyMz
if nargin < 3, loss_period = 0; end  % How long between signal loss events 10
if nargin < 2, loss_length = 0; end  % Length of signal loss 2
if nargin < 1
    [imu,imu_p,filename] = wsdread();
else
    [imu,imu_p,filename] = wsdread(INSfile);
end;

% Map the  INS wsd file to the correct WASP file
mapfile = fopen('WASP_INS_Data/20111220/filemapping.csv'); 
filemapping = textscan(mapfile,'%s %s %d %f %f %f %f %f %f', 'delimiter',',');
fclose(mapfile); 
index = find(ismember(filemapping{1}, filename)==1);
WASPdatafile = strcat('WASP_INS_Data/20111220/',filemapping{2}(index));
col = filemapping{3}(index);
front = [filemapping{4}(index); filemapping{5}(index); filemapping{6}(index)];
ms_bias = [filemapping{7}(index); filemapping{8}(index); filemapping{9}(index)];

% Load the WASP data in format "TsXposYpos"
WASPdata = csvread(WASPdatafile{1},0,col);
WASPdata(:,col+1:size(WASPdata,2)) = []; % drop fields not needed
WASPdata(1:4,:) = []; % drop first 4 obs
WASPdata( isnan(WASPdata(:,1)) , :) = []; % drop NaN times
WASPdata(:,2) = -WASPdata(:,2); % flip the x-axis on WASP to go from survey to map coordinates

% Synchronise the start of IMU and WASP
imu(1:find(imu(:,1) < WASPdata(1,1),1,'last'),:) = [];
WASPdata(1:find(WASPdata(:,1) < imu(1,1),1,'last'), :) = [];

% Synchronise the end of IMU and WASP
imu(find(imu(:,1) > WASPdata(end,1),1,'first'):end,:) = [];
WASPdata(find(WASPdata(:,1) > imu(end,1),1,'first'):end,:) = [];

% Create some WASP dropouts if necessary
if loss_period > 0
    next_signal_loss = loss_period;
    delete_positions = [];
    signal_loss_errors = [];
    for t=1:size(WASPdata,1)
        if(WASPdata(t,1)-WASPdata(1,1) > next_signal_loss)
            if(WASPdata(t,1)-WASPdata(1,1) < next_signal_loss + loss_length)
                delete_positions = [delete_positions t]; 
            else
                signal_loss_errors = [signal_loss_errors [WASPdata(t,1); 0]];
                next_signal_loss = next_signal_loss + loss_period;
            end;
        end;
    end;
    WASPdata(delete_positions,:)=[];
end;

% Add a constant bias to fs x axis (comes out as negative)
%imu(:,5) = imu(:,5) + 200;

% Add a constant bias to gyro x axis
%imu(:,2) = imu(:,2) + 5;


% Create some more meaningful names, accel for integration and orientation
% are separated with different high freq denoising constants
ws = MovAvg2(1,imu(:,2:4))';   % Gyro in s-frame
fs = -MovAvg2(1,imu(:,5:7))';   % Accel in s-frame (for integration)
fso = -MovAvg2(82,imu(:,5:7))';   % Accel in s-frame (for orientation, more smoothing)
ms = MovAvg2(1,imu(:,11:13))'; % Mag in s-frame
WASPloc = WASPdata(:,2:3)';

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%   SETUP

samples = 820; % How many samples used to estimate initial orientation, 
% (about 820 samples in 1 second)

% Timestamps
timestamps_IMU = imu(:,1)';% - imu(1,1);
timestamps_WASP = WASPdata(:,1)';% - WASPdata(1,1);
nS = size(timestamps_IMU,2);
nS_filter = size(timestamps_WASP,2);
dt = (timestamps_IMU(end)- timestamps_IMU(1))/(nS-1);
dt_filter = (timestamps_WASP(end)- timestamps_WASP(1))/(nS_filter-1);

% Allocate error feedback and INS output variables
[a, v, r, rpy] = deal(zeros(3,nS+1)); % INS output
[Cn2b] = deal(zeros(3,3,nS+1)); % INS orientation matrix
[wsc, fsc, fsoc] = deal(zeros(3,nS)); % Bias corrected gyro and accel in s-frame
[ba, bg, epsilon, dv, dr, actual_ba, actual_bg] = deal(zeros(3,nS_filter+1)); % filter error estimates
[innov, Sk] = deal(zeros(9,nS_filter+1));       % filter residuals + std dev
[Pk] = deal(zeros(15,nS_filter+1));             % filter std dev

% Initialise INS position using first WASP observation 
r(:,1) = [WASPloc(:,1);0]; % Assume z = 0;

% Environment calibrated magnetic vector and assumed gravity vector in
% n-frame (refer to plotmap function for the n-frame orientation)
%mn_cal = [-200; -126; 523]; % This is calibrated from the sensor
mn_cal = RPY2DCM(deg2rad([0; 0; 207.5]))*[242; -5.3; 515];
% This is calculated from http://www.ngdc.noaa.gov/geomagmodels/struts/calcIGRFWMM
% then uses http://googlecompass.com/ to estimate the rotation of the
% n-frame from north
gn_cal = [0; 0; 1000]; % Doesn't seem to matter which one is used

% Remove previously estimated magnetometer bias
for t=1:nS
    ms(:,t) = ms(:,t) - ms_bias;
end;

% Estimate initial orientation from observed magnetic vector and gravity 
gn = mean(fs(:,1:samples),2);
mn = mean(ms(:,1:samples),2);
mn_cal_perp = mn_cal - dot(mn_cal,gn_cal)/dot(gn_cal,gn_cal)*gn_cal;
mn_perp = mn - dot(mn,gn)/dot(gn,gn)*gn; % Component of magnetic vector in xy plane
Cb2n = wahba([gn_cal,mn_cal_perp],[gn,mn_perp]); 
% Cb2n = wahba([gn_cal,mn_cal],[gn,mn]);
Cn2b(:,:,1) = Cb2n';
Cs2b = eye(3); % Assume body and sensor framed are aligned for now


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% PROCESSING LOOP

%   Current feedback estimates
dr_feedback = zeros(3,1);
dv_feedback = zeros(3,1);
epsilon_feedback = zeros(3,1);

tf = 1;     % timestep for the filter
for t=1:nS  % timestep for the INS
    
    %bg(:,tf) = [0.42; 0.23; -0.1]; % manually tuned bias correction, for testing 315 circle
    
    % Apply bias corrections   
    wsc(:,t) = ws(:,t) - bg(:,tf);    % bias corrected gyro in s-frame
    fsc(:,t) = fs(:,t) - ba(:,tf);    % bias corrected accel in s-frame
    fsoc(:,t) = fso(:,t) - ba(:,tf);    % bias corrected accel in s-frame
    wb = Cs2b*wsc(:,t); % bias corrected gyro in b-frame
    fb = Cs2b*fsc(:,t); % bias corrected accel in b-frame
    
    actual_ba(:,t) = fs(:,t) - Cs2b'*Cb2n'*gn_cal;
    actual_bg(:,t) = ws(:,t);
  
    % INS integration
    [a(:,t+1), v(:,t+1), r(:,t+1), Cb2n]...
        = INS(v(:,t), r(:,t), Cb2n, dv_feedback, dr_feedback, epsilon_feedback, wb, fb, dt, gn_cal); 
    Cn2b(:,:,t+1) = Cb2n';
    rpy(:,t+1) = rad2deg(DCM2RPY(Cb2n')); 
    
    % Error estimation with filter 
    if( tf <= numel(timestamps_WASP) && t < numel(timestamps_IMU) && timestamps_WASP(tf) < timestamps_IMU(t+1) )  
        % Run filter updates only when WASP available
        
        dr_wasp = r(:,t+1) - [WASPloc(:,tf); 0]; % augment by assuming vertical movement is wrong

        if(size(signal_loss_errors,1)>0)
            signal_loss_errors(2,signal_loss_errors(1,:) == timestamps_WASP(tf)) = norm(dr_wasp(1:2));
        end;
        
        if (tf > 1), dt_filter = timestamps_WASP(tf)- timestamps_WASP(tf-1); end;
        
        [ ba_error, bg_error, dv(:,tf+1), dr(:,tf+1), epsilon(:,tf+1), innov(:,tf+1), Sk(:,tf+1), Pk(:,tf+1) ] ...
            = errorfilter( Cs2b, Cb2n, fsoc(:,t), ms(:,t), dt_filter, dr_wasp, mn_cal, gn_cal );

        ba(:,tf+1) = ba(:,tf) + ba_error;
        bg(:,tf+1) = bg(:,tf) + bg_error;
        
        dr_feedback = dr(:,tf+1); 
        dv_feedback = dv(:,tf+1);
        epsilon_feedback = epsilon(:,tf+1);
        
        tf = tf + 1;        % Increment filter time step
        
    else % Reset position errors (but not bias errors), since bias is corrected always, 
        % position error is only fed back once
        
        dr_feedback = zeros(3,1);
        dv_feedback = zeros(3,1);
        epsilon_feedback = zeros(3,1);
   
    end;
    
end;  

if loss_period > 0
    signal_loss_mean_error = mean(signal_loss_errors(2,:))
    signal_loss_median_error = median(signal_loss_errors(2,:))
end;

% for i=1:size(Cn2b,3)-1
%     grav_error_nav(:,i) = Cn2b(:,:,i)'*fs(:,i) - gn_cal;
%     grav_error_bod(:,i) = fs(:,i) - Cn2b(:,:,i)*gn_cal;
% end;
% grav_error_nav = MovAvg2(8200,grav_error_nav')';
% figure, plot(timestamps_IMU, grav_error_nav), title('Gravity error in n-frame');
% 
% grav_error_bod = MovAvg2(8200,grav_error_bod')';
% figure, plot(timestamps_IMU, grav_error_bod), title('Gravity error in b-frame');

% figure, plot(timestamps_IMU, ms), title('Bias corrected magnetometer'), grid;

