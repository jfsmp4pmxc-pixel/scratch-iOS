import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { saveProject, listProjects, loadProject, deleteProject } from '../../lib/scratch-storage';
import styles from './project-manager.css';

class ProjectManager extends React.Component {
    constructor(props) {
        super(props);
        this.state = {
            projects: [],
            loading: true,
            newName: ''
        };
    }

    componentDidMount() {
        this.refresh();
    }

    refresh = async () => {
        this.setState({loading: true});
        const projects = await listProjects();
        this.setState({projects, loading: false});
    };

    handleSave = async () => {
        const name = (this.state.newName || `project_${Date.now()}`).trim();
        try {
            await saveProject(this.props.vm, name);
            this.setState({newName: ''});
            await this.refresh();
            alert(`Đã lưu: ${name}`);
        } catch (e) {
            alert('Lỗi khi lưu: ' + e.message);
        }
    };

    handleLoad = async (fileName) => {
        if (!confirm(`Mở dự án "${fileName}"? Thay đổi hiện tại sẽ mất.`)) return;
        try {
            await loadProject(this.props.vm, fileName);
            this.props.onClose();
        } catch (e) {
            alert('Lỗi khi mở: ' + e.message);
        }
    };

    handleDelete = async (e, fileName) => {
        e.stopPropagation();
        if (!confirm(`Xoá "${fileName}"?`)) return;
        await deleteProject(fileName);
        await this.refresh();
    };

    render() {
        return (
            <div className={styles.overlay}>
                <div className={styles.modal}>
                    <div className={styles.header}>
                        <h2>Dự án của tôi</h2>
                        <button className={styles.closeBtn} onClick={this.props.onClose}>✕</button>
                    </div>

                    <div className={styles.saveRow}>
                        <input
                            type="text"
                            placeholder="Tên dự án..."
                            value={this.state.newName}
                            onChange={e => this.setState({newName: e.target.value})}
                        />
                        <button onClick={this.handleSave}>💾 Lưu dự án hiện tại</button>
                    </div>

                    <div className={styles.list}>
                        {this.state.loading && <p>Đang tải...</p>}
                        {!this.state.loading && this.state.projects.length === 0 &&
                            <p className={styles.empty}>Chưa có dự án nào</p>}
                        {this.state.projects.map(p => (
                            <div
                                key={p.name}
                                className={styles.item}
                                onClick={() => this.handleLoad(p.name)}
                            >
                                <span className={styles.itemName}>{p.displayName}</span>
                                <button
                                    className={styles.delBtn}
                                    onClick={e => this.handleDelete(e, p.name)}
                                >🗑</button>
                            </div>
                        ))}
                    </div>
                </div>
            </div>
        );
    }
}

ProjectManager.propTypes = {
    vm: PropTypes.object,
    onClose: PropTypes.func.isRequired
};

const mapStateToProps = state => ({
    vm: state.scratchGui.vm
});

export default connect(mapStateToProps)(ProjectManager);