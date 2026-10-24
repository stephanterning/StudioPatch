#pragma once
#ifdef __cplusplus
extern "C" {
#endif
char* SPInventory(void);
char* SPFollowMaster(const char* config);
char* SPSetChannelNames(const char* names);
char* SPReadChannelLabels(const char* uid);
char* SPSetChannelLabel(const char* request);
char* SPConfigure(const char* config);
char* SPStart(const char* config);
char* SPUpdateRouting(const char* config);
char* SPStatus(void);
void SPStop(void);
void SPFree(char* result);
#ifdef __cplusplus
}
#endif
#ifdef __cplusplus
extern "C" {
#endif
char* SPRuntimeRates(const char* config);
char* SPSetHardwareRate(const char* config);
#ifdef __cplusplus
}
#endif
#ifdef __cplusplus
extern "C" {
#endif
char* SPAcknowledgeRate(const char* config);
#ifdef __cplusplus
}
#endif
