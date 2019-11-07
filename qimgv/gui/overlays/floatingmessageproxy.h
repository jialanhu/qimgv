#ifndef FLOATINGMESSAGEPROXY_H
#define FLOATINGMESSAGEPROXY_H

#include "gui/overlays/floatingmessage.h"

class FloatingMessageProxy
{
public:
    FloatingMessageProxy(FloatingWidgetContainer *parent);
    ~FloatingMessageProxy();
    void showMessage(QString text, FloatingMessageIcon icon, int duration);
    void showMessage(QString text, FloatingWidgetPosition position, FloatingMessageIcon icon, int duration);
    void init();
private:
    FloatingWidgetContainer *container;
    FloatingMessage *overlay;
};

#endif // FLOATINGMESSAGEPROXY_H