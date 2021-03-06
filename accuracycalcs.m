% This is a script that produces a plot showing the required orientation 
% accuracy for this to actually work


t = [0:0.1:5];
epsilon = [0.1; 1; 5]; % orientation error from vertical in degrees

dr = 0.5 * mg2ms(sin(deg2rad(epsilon))*1000) * t.^2;

figure, plot (t, dr), grid,
axis([0; 5; 0; 5]),
title('Effect of orientation error from vertical on integrated position'),
xlabel('Time secs'),
ylabel('Position error m') , legend('0.1 deg error', '1 deg error','5 deg error');