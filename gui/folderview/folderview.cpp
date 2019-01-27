#include "folderview.h"
#include "ui_folderview.h"

FolderView::FolderView(QWidget *parent) :
    QWidget(parent),
    ui(new Ui::FolderView)
{
    //this->setAttribute(Qt::WA_NoMousePropagation, true);
    ui->setupUi(this);

    ui->openButton->setAction("open");
    ui->settingsButton->setAction("openSettings");
    ui->closeButton->setAction("exit");
    ui->docViewButton->setAction("documentView");

    ui->directoryPathLabel->setAccessibleName("FolderViewPathLabel");
    ui->zoomSlider->setMinimum(ui->thumbnailGrid->THUMBNAIL_SIZE_MIN);
    ui->zoomSlider->setMaximum(ui->thumbnailGrid->THUMBNAIL_SIZE_MAX);
    ui->zoomSlider->setSingleStep(ui->thumbnailGrid->ZOOM_STEP);
    ui->zoomSlider->setPageStep(ui->thumbnailGrid->ZOOM_STEP);

    connect(ui->thumbnailGrid, SIGNAL(thumbnailPressed(int)),
            this, SIGNAL(thumbnailPressed(int)));
    connect(ui->thumbnailGrid, SIGNAL(thumbnailRequested(QList<int>, int)),
            this, SIGNAL(thumbnailRequested(QList<int>, int)));

    connect(ui->zoomSlider, SIGNAL(valueChanged(int)), ui->thumbnailGrid, SLOT(setThumbnailSize(int)));
    connect(ui->thumbnailGrid, SIGNAL(thumbnailSizeChanged(int)), this, SLOT(onThumbnailSizeChanged(int)));
    ui->thumbnailGrid->setThumbnailSize(settings->folderViewIconSize());
}

void FolderView::onThumbnailSizeChanged(int newSize) {
    ui->zoomSlider->setValue(newSize);
    settings->setFolderViewIconSize(newSize);
}

FolderView::~FolderView() {
    delete ui;
}

// probably unneeded
void FolderView::show() {
    QWidget::show();
    ui->thumbnailGrid->setFocus();
}

// probably unneeded
void FolderView::hide() {
    QWidget::hide();
    ui->thumbnailGrid->clearFocus();
}

void FolderView::setCloseButtonEnabled(bool mode) {
    ui->closeButton->setHidden(!mode);
}

void FolderView::focusInEvent(QFocusEvent *event) {
    Q_UNUSED(event)
    ui->thumbnailGrid->setFocus();
}

void FolderView::populate(int count) {
    ui->thumbnailGrid->populate(count);
}

void FolderView::setThumbnail(int pos, std::shared_ptr<Thumbnail> thumb) {
    ui->thumbnailGrid->setThumbnail(pos, thumb);
}

void FolderView::selectIndex(int index) {
    ui->thumbnailGrid->selectIndex(index);
}

void FolderView::setDirectoryPath(QString path) {
    ui->directoryPathLabel->setText(path);
}

void FolderView::addItem() {
    ui->thumbnailGrid->addItem();
}

void FolderView::insertItem(int index) {
    ui->thumbnailGrid->insertItem(index);
}

void FolderView::removeItem(int index) {
    ui->thumbnailGrid->removeItem(index);
}

// prevent passthrough to parent
void FolderView::wheelEvent(QWheelEvent *event) {
    event->accept();
}

void FolderView::paintEvent(QPaintEvent *) {
    QStyleOption opt;
    opt.init(this);
    QPainter p(this);
    style()->drawPrimitive(QStyle::PE_Widget, &opt, &p, this);
}
