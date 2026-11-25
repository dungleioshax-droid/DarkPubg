#pragma once
#include <string>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

namespace setting {
    inline std::string Lang(const char *en, const char *vi) {
#ifdef __OBJC__
        NSString *l = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppLanguage"];
        if ([l isEqualToString:@"en"]) return en ? std::string(en) : "";
#endif
        return vi ? std::string(vi) : (en ? std::string(en) : "");
    }
}
