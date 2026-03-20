#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach.h>
#import <sys/sysctl.h>

static dispatch_source_t _timer;
static UILabel *fpsLabel;
static UILabel *cpuLabel;
static UILabel *ramLabel;
static UILabel *batteryLabel;

double FPSPerSecond = 0;

// ─── CPU Usage ───
static float getCPUUsage() {
	kern_return_t kr;
	thread_array_t thread_list;
	mach_msg_type_number_t thread_count;
	
	kr = task_threads(mach_task_self(), &thread_list, &thread_count);
	if (kr != KERN_SUCCESS) return -1;
	
	float total = 0;
	for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
		thread_info_data_t thinfo;
		mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
		kr = thread_info(thread_list[i], THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
		if (kr == KERN_SUCCESS) {
			thread_basic_info_t basic = (thread_basic_info_t)thinfo;
			if (!(basic->flags & TH_FLAGS_IDLE))
				total += basic->cpu_usage / (float)TH_USAGE_SCALE * 100.0;
		}
	}
	vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
	return total;
}

// ─── RAM Usage (app) ───
static float getAppMemoryMB() {
	struct mach_task_basic_info info;
	mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
	kern_return_t kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &size);
	if (kr != KERN_SUCCESS) return 0;
	return info.resident_size / (1024.0 * 1024.0);
}

// ─── Free RAM (system) ───
static float getFreeMemoryMB() {
	mach_port_t host = mach_host_self();
	vm_statistics64_data_t vmstat;
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	kern_return_t kr = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vmstat, &count);
	if (kr != KERN_SUCCESS) return 0;
	vm_size_t pageSize;
	host_page_size(host, &pageSize);
	return (vmstat.free_count + vmstat.purgeable_count) * (float)pageSize / (1024.0 * 1024.0);
}

static void startRefreshTimer(){
	_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_walltime(NULL, 0), (1.0/5.0) * NSEC_PER_SEC, 0);

    dispatch_source_set_event_handler(_timer, ^{
    	[fpsLabel setText:[NSString stringWithFormat:@"%.0f FPS",FPSPerSecond]];
    	[cpuLabel setText:[NSString stringWithFormat:@"CPU %.0f%%", getCPUUsage()]];
    	[ramLabel setText:[NSString stringWithFormat:@"%.0fMB | %.0fMB", getAppMemoryMB(), getFreeMemoryMB()]];
    	
    	float battery = [[UIDevice currentDevice] batteryLevel] * 100;
    	UIDeviceBatteryState state = [[UIDevice currentDevice] batteryState];
    	NSString *stateStr = @"";
    	if (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull) stateStr = @"⚡";
    	[batteryLabel setText:[NSString stringWithFormat:@"%@%.0f%%", stateStr, battery]];
    	
    	// Color FPS based on value
    	if (FPSPerSecond >= 55) {
    		fpsLabel.textColor = [UIColor colorWithRed:0.30 green:0.85 blue:0.40 alpha:1.0]; // green
    	} else if (FPSPerSecond >= 30) {
    		fpsLabel.textColor = [UIColor colorWithRed:0.99 green:0.80 blue:0.00 alpha:1.0]; // yellow
    	} else {
    		fpsLabel.textColor = [UIColor colorWithRed:0.95 green:0.30 blue:0.25 alpha:1.0]; // red
    	}
    	
    	// Color battery based on level
    	if (battery >= 50) {
    		batteryLabel.textColor = [UIColor colorWithRed:0.30 green:0.85 blue:0.40 alpha:1.0];
    	} else if (battery >= 20) {
    		batteryLabel.textColor = [UIColor colorWithRed:0.99 green:0.80 blue:0.00 alpha:1.0];
    	} else {
    		batteryLabel.textColor = [UIColor colorWithRed:0.95 green:0.30 blue:0.25 alpha:1.0];
    	}
    });
    dispatch_resume(_timer); 
}

#pragma mark ui
#define kOverlayWidth 130
#define kRowHeight 18
#define kPadding 6
%group ui
%hook UIWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
        
        CGRect screenBounds = [[UIScreen mainScreen] bounds];
        CGFloat maxDim = MAX(screenBounds.size.width, screenBounds.size.height);
        CGFloat x = maxDim - kOverlayWidth - 10;
        CGFloat y = 12;
        
        // Container view
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(x, y, kOverlayWidth, kRowHeight * 4 + kPadding * 2)];
        container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        container.layer.cornerRadius = 8;
        container.clipsToBounds = YES;
        container.userInteractionEnabled = NO;
        container.layer.zPosition = MAXFLOAT;
        
        UIFont *font = [UIFont fontWithName:@"Menlo-Bold" size:11];
        UIColor *defaultColor = [UIColor colorWithRed:0.99 green:0.80 blue:0.00 alpha:1.0];
        
        // FPS row
        fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(kPadding, kPadding, kOverlayWidth - kPadding*2, kRowHeight)];
        fpsLabel.font = font;
        fpsLabel.textColor = defaultColor;
        fpsLabel.textAlignment = NSTextAlignmentLeft;
        [container addSubview:fpsLabel];
        
        // CPU row
        cpuLabel = [[UILabel alloc] initWithFrame:CGRectMake(kPadding, kPadding + kRowHeight, kOverlayWidth - kPadding*2, kRowHeight)];
        cpuLabel.font = font;
        cpuLabel.textColor = [UIColor colorWithRed:0.40 green:0.70 blue:1.0 alpha:1.0];
        cpuLabel.textAlignment = NSTextAlignmentLeft;
        [container addSubview:cpuLabel];
        
        // RAM row (app | free)
        ramLabel = [[UILabel alloc] initWithFrame:CGRectMake(kPadding, kPadding + kRowHeight*2, kOverlayWidth - kPadding*2, kRowHeight)];
        ramLabel.font = font;
        ramLabel.textColor = [UIColor colorWithRed:0.75 green:0.55 blue:1.0 alpha:1.0];
        ramLabel.textAlignment = NSTextAlignmentLeft;
        [container addSubview:ramLabel];
        
        // Battery row
        batteryLabel = [[UILabel alloc] initWithFrame:CGRectMake(kPadding, kPadding + kRowHeight*3, kOverlayWidth - kPadding*2, kRowHeight)];
        batteryLabel.font = font;
        batteryLabel.textColor = [UIColor colorWithRed:0.30 green:0.85 blue:0.40 alpha:1.0];
        batteryLabel.textAlignment = NSTextAlignmentLeft;
        [container addSubview:batteryLabel];
        
        [self addSubview:container];
        startRefreshTimer();
    });
	return %orig;
}
%end
%end


void frameTick(){
	static double FPS_temp = 0;
	static double starttick = 0;
	static double endtick = 0;
	static double deltatick = 0;
	static double frameend = 0;
	static double framedelta = 0;
	static double frameavg = 0;
	
	if (starttick == 0) starttick = CACurrentMediaTime()*1000.0;
	endtick = CACurrentMediaTime()*1000.0;
	framedelta = endtick - frameend;
	frameavg = ((9*frameavg) + framedelta) / 10;
    FPSPerSecond = 1000.0f / (double)frameavg;
	frameend = endtick;
	
	FPS_temp++;
	deltatick = endtick - starttick;
	if (deltatick >= 1000.0f) {
		starttick = CACurrentMediaTime()*1000.0;
		FPSPerSecond = FPS_temp - 1;
		FPS_temp = 0;
	}
	
	return;
}


#pragma mark gl
%group gl
%hook EAGLContext 
- (BOOL)presentRenderbuffer:(NSUInteger)target{
	BOOL ret=%orig;
	frameTick();
	return ret;
}
%end
%end

#pragma mark metal
// Hook CAMetalLayer instead of CAMetalDrawable (which is a protocol)
%group metal
%hook CAMetalLayer
- (id)nextDrawable{
	id drawable = %orig;
	frameTick();
	return drawable;
}
%end
%end


%ctor{
	NSLog(@"ctor: FPSIndicator");

	%init(ui);
	%init(gl);
	%init(metal);
}
